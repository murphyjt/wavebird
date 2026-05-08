import CoreHID
import Foundation
import Observation

enum DeviceConnectionState: Sendable, Equatable {
    case discovered
    case connecting
    case connected
    case disconnected
    case failed(String)
}

struct DeviceRecord: Identifiable {
    let id: DeviceID
    let profile: any ControllerProfile
    var advertisement: AdvertisementInfo
    var connectionState: DeviceConnectionState
    var virtualHID: VirtualHIDDevice?
}

@Observable
final class BridgeCoordinator {
    let profiles: [any ControllerProfile]
    let transports: [any Transport]

    private(set) var devices: [DeviceID: DeviceRecord] = [:]
    private(set) var isScanning = false
    private(set) var lastReportSnapshot: ReportSnapshot?
    private(set) var log: [String] = []

    @ObservationIgnored
    private var consumerTask: Task<Void, Never>?

    init(profiles: [any ControllerProfile], transports: [any Transport]) {
        self.profiles = profiles
        self.transports = transports
    }

    func start() async {
        guard consumerTask == nil else { return }
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

    private func handle(_ event: TransportEvent, kind: TransportKind) async {
        switch event {
        case .discovered(let id, let info):
            guard devices[id] == nil else { return }
            guard let profile = profile(forProductID: info.productID, kind: kind) else { return }
            devices[id] = DeviceRecord(
                id: id,
                profile: profile,
                advertisement: info,
                connectionState: .discovered,
                virtualHID: nil
            )
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
            guard let profile = devices[id]?.profile else { return }
            if let vhid = VirtualHIDDevice(
                descriptor: profile.hidDescriptor,
                vendorID: profile.hidVendorID,
                productID: profile.hidProductID,
                productName: profile.name,
                transport: kind == .ble ? .bluetoothLowEnergy : .usb
            ) {
                await vhid.activate()
                devices[id]?.virtualHID = vhid
            }

        case .disconnected(let id, _):
            devices[id]?.connectionState = .disconnected
            devices[id]?.virtualHID = nil

        case .reportReceived(let id, let reportID, let data):
            guard let record = devices[id] else { return }
            lastReportSnapshot = ReportSnapshot(deviceID: id, data: data)
            let parsed: ControllerState?
            switch kind {
            case .ble: parsed = record.profile.parseBLEReport(data)
            case .usb: parsed = record.profile.parseUSBReport(data, reportID: reportID ?? 0)
            }
            if let state = parsed, let vhid = record.virtualHID {
                let report = record.profile.buildHIDReport(state)
                try? await vhid.dispatch(report)
            }

        case .error(_, let msg):
            appendLog(msg)
        }
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
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
}
