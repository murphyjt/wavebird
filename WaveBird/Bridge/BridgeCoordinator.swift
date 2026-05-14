import CoreHID
import Foundation
import Observation

@Sendable func stderrLog(_ line: String) {
    FileHandle.standardError.write(Data("\(line)\n".utf8))
}

enum DeviceConnectionState: Sendable, Equatable {
    case discovered
    case connecting
    case connected
    case ready
    case disconnected
    case failed(String)
}

struct DeviceRecord: Identifiable {
    let id: DeviceID
    let profile: any ControllerProfile
    var advertisement: AdvertisementInfo
    var connectionState: DeviceConnectionState
    var virtualHID: VirtualHIDDevice?
    var reportRate: Double = 0       // reports received per second over BLE
    var controllerRate: Double = 0   // counter ticks produced by the controller per second
    var serial: String? = nil
    var firmware: FirmwareInfo? = nil
    var triggerZeros: (left: UInt8, right: UInt8)? = nil
    var calibration = StickCalibrationPair()
    var outputMode: HIDOutputMode
    // Mode captured at the moment the virtual HID device was created. We
    // intentionally keep using this instead of the record's live outputMode
    // while republishing so reports keep matching the active descriptor.
    var activeOutputMode: HIDOutputMode = .native
    // Set when activeOutputMode == .switchPro. The spoof emulates Nintendo's
    // BT subcommand handshake so Apple's driver binds GameController.framework,
    // and produces live Report 0x3F/0x30 input depending on which mode the
    // driver asked for.
    var switchProSpoof: SwitchProSpoof?
}

@MainActor
@Observable
final class BridgeCoordinator {
    let profiles: [any ControllerProfile]
    let transports: [any Transport]

    private(set) var devices: [DeviceID: DeviceRecord] = [:]
    private(set) var isScanning = false
    private(set) var lastReportSnapshot: ReportSnapshot?

    private static let outputModeDefaultsKey = "WaveBird.hidOutputMode"
    private let defaultOutputMode: HIDOutputMode

    @ObservationIgnored
    private var consumerTask: Task<Void, Never>?

    @ObservationIgnored
    private var rateTask: Task<Void, Never>?

    @ObservationIgnored
    private var reportCounts: [DeviceID: Int] = [:]

    @ObservationIgnored
    private var lastCounter: [DeviceID: UInt32] = [:]

    @ObservationIgnored
    private var counterDeltas: [DeviceID: Int] = [:]

    // Per-device latest-state channels. The consumer yields parsed states here
    // (non-blocking); a separate dispatch task picks up the newest and sends it
    // to the virtual HID device. bufferingNewest(1) discards stale states if the
    // dispatch task falls behind, so we always forward the most recent input.
    @ObservationIgnored
    private var stateContinuations: [DeviceID: AsyncStream<ControllerState>.Continuation] = [:]

    @ObservationIgnored
    private var dispatchTasks: [DeviceID: Task<Void, Never>] = [:]

    // Prevents App Nap / background throttling while a controller is active.
    // Wrapped so that deinit ends the activity regardless of isolation.
    @ObservationIgnored
    private var activity: ActivityToken?

    private final class ActivityToken: @unchecked Sendable {
        private let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        deinit { ProcessInfo.processInfo.endActivity(token) }
    }

    init(profiles: [any ControllerProfile], transports: [any Transport]) {
        self.profiles = profiles
        self.transports = transports
        let stored = UserDefaults.standard.string(forKey: Self.outputModeDefaultsKey)
        self.defaultOutputMode = stored.flatMap(HIDOutputMode.init(rawValue:)) ?? .native
    }

    // Persist the new default for future devices, update this device's desired
    // mode, and republish its virtual HID if it is currently active.
    func setOutputMode(_ mode: HIDOutputMode, for id: DeviceID) async {
        guard devices[id]?.outputMode != mode else { return }
        devices[id]?.outputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.outputModeDefaultsKey)
        guard devices[id]?.virtualHID != nil else { return }
        await republishVirtualHID(for: id, mode: mode)
    }

    private func output(for record: DeviceRecord, mode: HIDOutputMode) -> any HIDOutputProfile {
        switch mode {
        case .native:     return NativeOutput(profile: record.profile)
        case .switchPro:  return SwitchProOutput()
        case .dualShock4: return DualShock4Output()
        case .dualSense:  return DualSenseOutput()
        case .xboxSeries: return XboxSeriesOutput()
        }
    }

    private func makeVirtualHID(for record: DeviceRecord, mode: HIDOutputMode) -> (VirtualHIDDevice, SwitchProSpoof?)? {
        let out = output(for: record, mode: mode)
        let spoof: SwitchProSpoof? = (mode == .switchPro) ? SwitchProSpoof(log: stderrLog) : nil
        let onSetReport = makeSetReportHandler(spoof: spoof)
        guard let vhid = VirtualHIDDevice(
            descriptor: out.descriptor,
            vendorID: out.vendorID,
            productID: out.productID,
            productName: out.productName,
            manufacturer: out.manufacturer,
            versionNumber: out.versionNumber,
            serialNumber: record.serial,
            transport: hidTransport(for: record, mode: mode),
            onSetReport: onSetReport
        ) else { return nil }
        return (vhid, spoof)
    }

    // Always-on diagnostic log for output reports the host sends us. For the
    // Switch Pro spoof, also routes the request into the subcommand handler.
    private func makeSetReportHandler(spoof: SwitchProSpoof?) -> VirtualHIDDevice.SetReportHandler {
        return { [weak spoof] device, type, id, data in
            let idStr = id.map { String(format: "0x%02X", $0.rawValue) } ?? "-"
            let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            stderrLog("[hid] setReport type=\(type) id=\(idStr) len=\(data.count) [\(hex)]")
            if let spoof {
                await spoof.handleSetReport(device: device, type: type, id: id, data: data)
            }
        }
    }

    private func hidTransport(for record: DeviceRecord, mode: HIDOutputMode) -> HIDDeviceTransport {
        switch mode {
        case .native:
            return record.id.transport == .ble ? .bluetoothLowEnergy : .usb
        case .switchPro, .dualShock4, .dualSense, .xboxSeries:
            return .usb
        }
    }

    private func republishVirtualHID(for id: DeviceID, mode: HIDOutputMode) async {
        guard var record = devices[id] else { return }
        record.virtualHID = nil
        devices[id]?.virtualHID = nil
        devices[id]?.switchProSpoof = nil
        try? await Task.sleep(for: .milliseconds(150))
        guard let (vhid, spoof) = makeVirtualHID(for: record, mode: mode) else {
            devices[id]?.connectionState = .failed("Failed to create virtual HID device")
            return
        }
        await vhid.activate()
        devices[id]?.virtualHID = vhid
        devices[id]?.switchProSpoof = spoof
        devices[id]?.activeOutputMode = mode
    }

    deinit {
        consumerTask?.cancel()
        rateTask?.cancel()
        for task in dispatchTasks.values { task.cancel() }
        for cont in stateContinuations.values { cont.finish() }
    }

    func start() async {
        guard consumerTask == nil else { return }
        activity = ActivityToken(ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Controller input bridging"
        ))
        let transports = self.transports
        consumerTask = Task { [weak self] in
            await withDiscardingTaskGroup { group in
                for transport in transports {
                    group.addTask { [weak self] in
                        for await event in transport.events {
                            await self?.handle(event, kind: transport.kind)
                        }
                    }
                }
            }
        }
        rateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.snapshotRates()
            }
        }
    }

    private func snapshotRates() {
        for (id, count) in reportCounts {
            devices[id]?.reportRate = Double(count)
        }
        for id in devices.keys where reportCounts[id] == nil {
            devices[id]?.reportRate = 0
        }
        for (id, delta) in counterDeltas {
            devices[id]?.controllerRate = Double(delta)
        }
        for id in devices.keys where counterDeltas[id] == nil {
            devices[id]?.controllerRate = 0
        }
        reportCounts.removeAll(keepingCapacity: true)
        counterDeltas.removeAll(keepingCapacity: true)
    }

    func toggleScan() async {
        let allMatchers: [TransportMatcher] = profiles.flatMap { p -> [TransportMatcher] in
            var ms: [TransportMatcher] = []
            if let bm = p.bleMatcher { ms.append(.ble(bm)) }
            if let um = p.usbMatcher { ms.append(.usb(um)) }
            return ms
        }
        if isScanning {
            for t in transports { await t.stopDiscovery() }
            isScanning = false
        } else {
            for t in transports { await t.startDiscovery(matchers: allMatchers) }
            isScanning = true
        }
    }

    private func startDispatch(for id: DeviceID) {
        dispatchTasks[id]?.cancel()
        stateContinuations[id]?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: ControllerState.self, bufferingPolicy: .bufferingNewest(1))
        stateContinuations[id] = continuation
        dispatchTasks[id] = Task { @MainActor [weak self] in
            for await state in stream {
                guard let self,
                      let record = self.devices[id],
                      let vhid = record.virtualHID else { continue }
                let out = self.output(for: record, mode: record.activeOutputMode)
                let report: Data
                if let spoof = record.switchProSpoof {
                    report = await spoof.buildReport(state, source: record.profile)
                } else {
                    report = out.buildReport(state, source: record.profile)
                }
                try? await vhid.dispatch(report)
                for secondary in out.buildSecondaryReports(state, source: record.profile) {
                    try? await vhid.dispatch(secondary)
                }
            }
        }
    }

    private func handle(_ event: TransportEvent, kind: TransportKind) async {
        switch event {
        case .discovered(let id, let info):
            if let existing = devices[id] {
                // Re-discovery: only re-attempt connect if not already in flight.
                switch existing.connectionState {
                case .connected, .connecting, .discovered, .ready: return
                case .disconnected, .failed: break
                }
                devices[id]?.connectionState = .discovered
                devices[id]?.advertisement = info
            } else {
                guard let profile = profile(forProductID: info.productID, kind: kind) else { return }
                devices[id] = DeviceRecord(
                    id: id,
                    profile: profile,
                    advertisement: info,
                    connectionState: .discovered,
                    virtualHID: nil,
                    outputMode: defaultOutputMode
                )
            }
            guard let t = transport(for: kind) else { return }
            do {
                try await t.connect(id)
            } catch {
                devices[id]?.connectionState = .failed(String(describing: error))
            }

        case .connecting(let id):
            devices[id]?.connectionState = .connecting

        case .connected(let id):
            devices[id]?.connectionState = .connected

        case .ready(let id):
            devices[id]?.connectionState = .ready
            guard let record = devices[id] else { return }
            if let (vhid, spoof) = makeVirtualHID(for: record, mode: record.outputMode) {
                await vhid.activate()
                devices[id]?.virtualHID = vhid
                devices[id]?.switchProSpoof = spoof
                devices[id]?.activeOutputMode = record.outputMode
                startDispatch(for: id)
            } else {
                devices[id]?.connectionState = .failed("Failed to create virtual HID device")
            }
        case .commandResponse(let id, let request, let response):
            FileHandle.standardError.write(Data("[ble] cmd:           \(hex(request))\n".utf8))
            if let response {
                let label = response.sourceHandle.map { String(format: "resp 0x%04X", $0) } ?? "resp       "
                FileHandle.standardError.write(Data("[ble] \(label): \(hex(response.data))\n".utf8))
                switch request.first {
                case 0x02:
                    // Strip 8-byte ACK header + 8-byte read-info to get the flash data.
                    let flashData = response.data.dropFirst(16)
                    // cmd 0x02/0x04 request: read address is little-endian at bytes [12..15].
                    var address = 0
                    if request.count >= 16 {
                        let b = request.startIndex
                        address = Int(request[b + 12])
                            | (Int(request[b + 13]) << 8)
                            | (Int(request[b + 14]) << 16)
                            | (Int(request[b + 15]) << 24)
                    }
                    FileHandle.standardError.write(Data("[ble] flash data:\n".utf8))
                    for line in hexdumpLines(flashData, baseOffset: address) {
                        FileHandle.standardError.write(Data("[ble]   \(line)\n".utf8))
                    }
                    switch address {
                    case 0x13000:
                        if let serial = NS2Responses.parseSerial(flashData) {
                            devices[id]?.serial = serial
                            FileHandle.standardError.write(Data("[ble] serial:        \(serial)\n".utf8))
                        }
                    case 0x13140:
                        if let zeros = NS2GameCubeProfile.parseTriggerZeros(flashData) {
                            devices[id]?.triggerZeros = zeros
                            FileHandle.standardError.write(Data("[ble] trigger zeros: L=\(zeros.left) R=\(zeros.right)\n".utf8))
                        }
                    case 0x13080:
                        if let cal = NS2Responses.parseStickCalibration(flashData) {
                            devices[id]?.calibration.left = cal
                            FileHandle.standardError.write(Data("[ble] L stick cal: n=(\(cal.neutralX),\(cal.neutralY)) max=(\(cal.maxX),\(cal.maxY)) min=(\(cal.minX),\(cal.minY))\n".utf8))
                        }
                    case 0x130C0:
                        if let cal = NS2Responses.parseStickCalibration(flashData) {
                            devices[id]?.calibration.right = cal
                            FileHandle.standardError.write(Data("[ble] R stick cal: n=(\(cal.neutralX),\(cal.neutralY)) max=(\(cal.maxX),\(cal.maxY)) min=(\(cal.minX),\(cal.minY))\n".utf8))
                        }
                    default:
                        break
                    }
                case 0x10:
                    // Strip 8-byte ACK header to get the firmware payload.
                    let payload = response.data.dropFirst(8)
                    if let info = NS2Responses.parseFirmwareInfo(payload) {
                        devices[id]?.firmware = info
                        FileHandle.standardError.write(Data("[ble] firmware:      \(info)\n".utf8))
                    }
                default:
                    break
                }
            } else {
                FileHandle.standardError.write(Data("[ble] resp:          (none)\n".utf8))
            }

        case .unmatchedResponse(_, let data, let sourceHandle):
            let label = sourceHandle.map { String(format: "0x%04X", $0) } ?? "?"
            FileHandle.standardError.write(Data("[ble] orphan \(label): \(hex(data))\n".utf8))

        case .disconnected(let id, _):
            dispatchTasks[id]?.cancel()
            dispatchTasks[id] = nil
            stateContinuations[id]?.finish()
            stateContinuations[id] = nil
            devices[id]?.connectionState = .disconnected
            devices[id]?.virtualHID = nil
            devices[id]?.switchProSpoof = nil
            devices[id]?.reportRate = 0
            devices[id]?.controllerRate = 0
            reportCounts[id] = nil
            counterDeltas[id] = nil
            lastCounter[id] = nil

        case .reportReceived(let id, let reportID, let data):
            guard let record = devices[id] else { return }
            lastReportSnapshot = ReportSnapshot(deviceID: id, data: data)
            reportCounts[id, default: 0] += 1
            // 32-bit LE counter at the head of the input report. Accumulate the per-report
            // delta so we can compare BLE delivery rate against controller production rate.
            if data.count >= 4 {
                let b = data.startIndex
                let counter = UInt32(data[b])
                    | (UInt32(data[b + 1]) << 8)
                    | (UInt32(data[b + 2]) << 16)
                    | (UInt32(data[b + 3]) << 24)
                if let prev = lastCounter[id] {
                    counterDeltas[id, default: 0] += Int(counter &- prev)
                }
                lastCounter[id] = counter
            }
            let parsed: ControllerState?
            switch kind {
            case .ble: parsed = record.profile.parseBLEReport(data, calibration: record.calibration)
            case .usb: parsed = record.profile.parseUSBReport(data, reportID: reportID ?? 0, calibration: record.calibration)
            }
            if var state = parsed {
                if let zeros = record.triggerZeros {
                    state.triggerL = state.triggerL >= zeros.left ? state.triggerL - zeros.left : 0
                    state.triggerR = state.triggerR >= zeros.right ? state.triggerR - zeros.right : 0
                }
                stateContinuations[id]?.yield(state)
            }

        case .error(_, let msg):
            stderrLog(msg)
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // Classic hexdump-style: `<OFFSET>: AA BB CC ... |ascii|`, 16 bytes per row.
    // baseOffset shifts the displayed offset so the column reflects an absolute address.
    private func hexdumpLines(_ data: Data, baseOffset: Int = 0) -> [String] {
        var lines: [String] = []
        let bytes = Array(data)
        var offset = 0
        while offset < bytes.count {
            let chunk = Array(bytes[offset..<min(offset + 16, bytes.count)])
            let first = chunk.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            let second = chunk.dropFirst(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            let hex = first + (second.isEmpty ? "" : "  " + second)
            let ascii = String(chunk.map {
                (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "."
            })
            let padded = hex.padding(toLength: 48, withPad: " ", startingAt: 0)
            lines.append("\(String(format: "0x%06X", baseOffset + offset)): \(padded) |\(ascii)|")
            offset += 16
        }
        return lines
    }

    private func profile(forProductID pid: UInt16, kind: TransportKind) -> (any ControllerProfile)? {
        switch kind {
        case .ble: return profiles.first { $0.bleMatcher?.productID == pid }
        case .usb: return profiles.first { $0.usbMatcher?.productID == pid }
        }
    }

    private func transport(for kind: TransportKind) -> (any Transport)? {
        transports.first { $0.kind == kind }
    }
}

struct ReportSnapshot: Sendable {
    let deviceID: DeviceID
    let data: Data

    var hex: String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // Same hex, broken into 8-byte lines.
    var hexLines: String {
        let b = data.startIndex
        return stride(from: 0, to: data.count, by: 8).map { start in
            let end = min(start + 8, data.count)
            return data[(b + start)..<(b + end)]
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
        }.joined(separator: "\n")
    }
}
