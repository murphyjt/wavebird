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
    var outputModeID: String
    // Mode captured at the moment the virtual HID device was created. We
    // intentionally keep using this instead of the record's live outputModeID
    // while republishing so reports keep matching the active descriptor.
    var activeOutputModeID: String = HIDOutputCatalog.nativeID
    // Per-virtual-device session created at .ready via the output profile's
    // makeSession(). Stateless outputs return self; stateful spoofs (Switch
    // Pro) return an actor that owns handshake/mode state for this connection.
    var session: (any HIDOutputSession)?
}

@MainActor
@Observable
final class BridgeCoordinator {
    let profiles: [any ControllerProfile]
    let transports: [any Transport]
    let catalog: HIDOutputCatalog

    private(set) var devices: [DeviceID: DeviceRecord] = [:]
    private(set) var isScanning = false
    private(set) var lastReportSnapshot: ReportSnapshot?

    private static let outputModeDefaultsKey = "WaveBird.hidOutputMode"
    private let defaultOutputModeID: String

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

    @ObservationIgnored
    private var rumbleRefreshBoxes: [DeviceID: RumbleRefreshBox] = [:]

    // Prevents App Nap / background throttling while a controller is active.
    // Wrapped so that deinit ends the activity regardless of isolation.
    @ObservationIgnored
    private var activity: ActivityToken?

    private final class ActivityToken: @unchecked Sendable {
        private let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        deinit { ProcessInfo.processInfo.endActivity(token) }
    }

    init(
        profiles: [any ControllerProfile],
        transports: [any Transport],
        catalog: HIDOutputCatalog = .default
    ) {
        self.profiles = profiles
        self.transports = transports
        self.catalog = catalog
        let stored = UserDefaults.standard.string(forKey: Self.outputModeDefaultsKey)
        self.defaultOutputModeID = stored.flatMap { catalog.entry(id: $0)?.id } ?? HIDOutputCatalog.nativeID
    }

    // Persist the new default for future devices, update this device's desired
    // mode, and republish its virtual HID if it is currently active.
    func setOutputMode(_ modeID: String, for id: DeviceID) async {
        guard devices[id]?.outputModeID != modeID else { return }
        devices[id]?.outputModeID = modeID
        UserDefaults.standard.set(modeID, forKey: Self.outputModeDefaultsKey)
        guard devices[id]?.virtualHID != nil else { return }
        await republishVirtualHID(for: id, modeID: modeID)
    }

    private func output(for record: DeviceRecord, modeID: String) -> any HIDOutputProfile {
        catalog.resolved(id: modeID).makeProfile(record.profile)
    }

    private func makeVirtualHID(for record: DeviceRecord, modeID: String) -> (VirtualHIDDevice, any HIDOutputSession)? {
        let out = output(for: record, modeID: modeID)
        let session = out.makeSession()
        let rumbleBox = RumbleRefreshBox()
        rumbleRefreshBoxes[record.id] = rumbleBox
        let onSetReport = makeSetReportHandler(id: record.id, transport: transport(for: record.id.transport), profile: record.profile, rumbleRefresh: rumbleBox, session: session)
        guard let vhid = VirtualHIDDevice(
            descriptor: out.descriptor,
            vendorID: out.vendorID,
            productID: out.productID,
            productName: out.productName,
            manufacturer: out.manufacturer,
            versionNumber: out.versionNumber,
            serialNumber: record.serial,
            transport: hidTransport(for: record),
            onSetReport: onSetReport
        ) else { return nil }
        return (vhid, session)
    }

    // Always-on diagnostic log for output reports the host sends us.
    // Routes rumble through session.parseRumble → profile.encodeRumble →
    // transport.sendVibration, and forwards everything to session.handleSetReport
    // for handshake/subcommand replies.
    private func makeSetReportHandler(
        id deviceID: DeviceID,
        transport: (any Transport)?,
        profile: any ControllerProfile,
        rumbleRefresh: RumbleRefreshBox,
        session: any HIDOutputSession
    ) -> VirtualHIDDevice.SetReportHandler {
        return { device, type, id, data in
            let idStr = id.map { String(format: "0x%02X", $0.rawValue) } ?? "-"
            let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            stderrLog("[hid] setReport type=\(type) id=\(idStr) len=\(data.count) [\(hex)]")

            if let cmd = session.parseRumble(type: type, id: id, data: data) {
                rumbleRefresh.cancel()
                if let payload = profile.encodeRumble(cmd) {
                    try? await transport?.sendVibration(payload, to: deviceID)
                }
                if let interval = cmd.refreshInterval, !cmd.isStop {
                    rumbleRefresh.replace(with: Task {
                        var counter = cmd.transmitCounter
                        while !Task.isCancelled {
                            try? await Task.sleep(for: interval)
                            counter = counter &+ 1
                            if let payload = profile.encodeRumble(cmd.withCounter(counter)) {
                                try? await transport?.sendVibration(payload, to: deviceID)
                            }
                        }
                    })
                }
            }

            await session.handleSetReport(device: device, type: type, id: id, data: data)
        }
    }

    private func hidTransport(for record: DeviceRecord) -> HIDDeviceTransport {
        // Always use .usb — BLE-transport virtual devices with output reports trigger
        // kIOReturnNoPower (IOServiceOpen:0xe00002e2). The transport hint is independent
        // of the real controller's connection and has no effect on input delivery.
        return .usb
    }

    private func republishVirtualHID(for id: DeviceID, modeID: String) async {
        guard var record = devices[id] else { return }
        record.virtualHID = nil
        devices[id]?.virtualHID = nil
        devices[id]?.session = nil
        rumbleRefreshBoxes[id]?.cancel()
        rumbleRefreshBoxes[id] = nil
        try? await Task.sleep(for: .milliseconds(150))
        guard let (vhid, session) = makeVirtualHID(for: record, modeID: modeID) else {
            devices[id]?.connectionState = .failed("Failed to create virtual HID device")
            return
        }
        await vhid.activate()
        devices[id]?.virtualHID = vhid
        devices[id]?.session = session
        devices[id]?.activeOutputModeID = modeID
    }

    deinit {
        consumerTask?.cancel()
        rateTask?.cancel()
        for task in dispatchTasks.values { task.cancel() }
        for cont in stateContinuations.values { cont.finish() }
        for box in rumbleRefreshBoxes.values { box.cancel() }
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
                      let vhid = record.virtualHID,
                      let session = record.session else { continue }
                let report = await session.buildReport(state)
                try? await vhid.dispatch(report)
                let secondaries = await session.buildSecondaryReports(state)
                for secondary in secondaries {
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
                    outputModeID: defaultOutputModeID
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
            if let (vhid, session) = makeVirtualHID(for: record, modeID: record.outputModeID) {
                await vhid.activate()
                devices[id]?.virtualHID = vhid
                devices[id]?.session = session
                devices[id]?.activeOutputModeID = record.outputModeID
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
            rumbleRefreshBoxes[id]?.cancel()
            rumbleRefreshBoxes[id] = nil
            devices[id]?.connectionState = .disconnected
            devices[id]?.virtualHID = nil
            devices[id]?.session = nil
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
                if record.activeOutputModeID == "ns2Passthrough" {
                    state.rawBLEData = data
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

// Holds the active Xbox rumble refresh task for one device. Lock-protected so the
// handler closure (any executor) and the main-actor coordinator can both cancel safely.
private final class RumbleRefreshBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func replace(with newTask: Task<Void, Never>) {
        lock.withLock {
            task?.cancel()
            task = newTask
        }
    }

    func cancel() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
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
