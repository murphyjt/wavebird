@preconcurrency import CoreBluetooth
import Foundation

enum BLETransportError: Error {
    case wrongTransport
    case unknownDevice
}

actor BLETransport: Transport {
    nonisolated let kind: TransportKind = .ble
    nonisolated let events: AsyncStream<TransportEvent>
    nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    private let queue: DispatchQueue
    private let central: CBCentralManager
    private let delegate: BLEDelegate

    private var matchers: [BLEMatcher] = []
    private var wantsScan: Bool = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var matcherByDevice: [UUID: BLEMatcher] = [:]
    private var inputChars: [UUID: CBCharacteristic] = [:]
    private var outputChars: [UUID: CBCharacteristic] = [:]
    // Per device, a map of subscribed response-char UUID → its handle.
    private var responseHandles: [UUID: [CBUUID: UInt16]] = [:]
    private var pendingResponses: [UUID: (request: Data, cont: CheckedContinuation<CommandResponseFrame?, Never>)] = [:]

    init() {
        let (stream, cont) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        let q = DispatchQueue.main
        let d = BLEDelegate()
        let c = CBCentralManager(delegate: d, queue: q)
        self.events = stream
        self.continuation = cont
        self.queue = q
        self.delegate = d
        self.central = c
        d.transport = self
    }

    deinit { continuation.finish() }

    func startDiscovery(matchers: [TransportMatcher]) async {
        let ble = matchers.compactMap { (m: TransportMatcher) -> BLEMatcher? in
            if case .ble(let bm) = m { return bm } else { return nil }
        }
        self.matchers = ble
        wantsScan = true
        startScanIfReady()
        retrieveAlreadyConnected()
    }

    private func retrieveAlreadyConnected() {
        guard central.state == .poweredOn else { return }
        let services = matchers.map(\.serviceUUID)
        guard !services.isEmpty else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: services)
        for p in connected {
            peripherals[p.identifier] = p
            guard let m = matchers.first else { continue }
            matcherByDevice[p.identifier] = m
            let id = DeviceID(transport: .ble, raw: p.identifier)
            let info = AdvertisementInfo(vendorID: 0x057E, productID: m.productID, localName: p.name, rssi: 0)
            continuation.yield(.discovered(id, info))
        }
    }

    func stopDiscovery() async {
        wantsScan = false
        guard central.state == .poweredOn else { return }
        central.stopScan()
    }

    private func startScanIfReady() {
        guard wantsScan, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func stateName(_ s: CBManagerState) -> String {
        switch s {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "poweredOff"
        case .poweredOn: "poweredOn"
        @unknown default: "unknown(\(s.rawValue))"
        }
    }

    func connect(_ id: DeviceID) async throws {
        guard id.transport == .ble else { throw BLETransportError.wrongTransport }
        guard let p = peripherals[id.raw] else { throw BLETransportError.unknownDevice }
        continuation.yield(.connecting(id))
        central.connect(p, options: ["kCBConnectOptionRequiresLowLatency": true])
    }

    func disconnect(_ id: DeviceID) async {
        guard let p = peripherals[id.raw] else { return }
        central.cancelPeripheralConnection(p)
    }

    func send(_ payload: Data, reportID: UInt8?, to id: DeviceID) async throws {
        guard let p = peripherals[id.raw], let ch = outputChars[id.raw] else {
            throw BLETransportError.unknownDevice
        }
        p.writeValue(payload, for: ch, type: writeType(for: ch))
    }

    func sendAwaitingResponse(_ payload: Data, to id: DeviceID, timeout: Duration) async throws -> CommandResponseFrame? {
        guard let p = peripherals[id.raw], let ch = outputChars[id.raw] else {
            throw BLETransportError.unknownDevice
        }
        // No response chars subscribed → fall back to fire-and-forget.
        guard (responseHandles[id.raw]?.isEmpty == false) else {
            p.writeValue(payload, for: ch, type: writeType(for: ch))
            return nil
        }
        precondition(pendingResponses[id.raw] == nil, "overlapping sendAwaitingResponse for \(id.raw)")
        let type = writeType(for: ch)
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandResponseFrame?, Never>) in
            pendingResponses[id.raw] = (request: payload, cont: cont)
            p.writeValue(payload, for: ch, type: type)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expirePending(id: id.raw)
            }
        }
    }

    private func expirePending(id: UUID) {
        if let pending = pendingResponses.removeValue(forKey: id) {
            pending.cont.resume(returning: nil)
        }
    }

    // Response framing echoes the request's cmd ID (byte 0) and subcmd (byte 3).
    private nonisolated func responseMatches(request: Data, response: Data) -> Bool {
        guard request.count >= 4, response.count >= 4 else { return false }
        let r = request.startIndex
        let s = response.startIndex
        return request[r] == response[s] && request[r + 3] == response[s + 3]
    }

    private nonisolated func writeType(for ch: CBCharacteristic) -> CBCharacteristicWriteType {
        ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
    }

    fileprivate func handleStateUpdate(_ state: CBManagerState) {
        if state != .poweredOn {
            continuation.yield(.error(nil, "BLE: \(stateName(state))"))
        }
        startScanIfReady()
    }

    fileprivate func handleDiscovery(
        peripheral: CBPeripheral,
        mfgData: Data?,
        localName: String?,
        rssi: Int
    ) {
        guard let mfg = mfgData,
              let parsed = BLEAdvertisementDecoder.decodeNintendoMfgData(mfg),
              parsed.vendorID == 0x057E else { return }

        guard let matcher = matchers.first(where: { $0.productID == parsed.productID }) else {
            let pidHex = String(format: "0x%04X", parsed.productID)
            continuation.yield(.error(nil, "Nintendo PID=\(pidHex) (no matching profile)"))
            return
        }
        peripherals[peripheral.identifier] = peripheral
        matcherByDevice[peripheral.identifier] = matcher
        let id = DeviceID(transport: .ble, raw: peripheral.identifier)
        let info = AdvertisementInfo(
            vendorID: parsed.vendorID,
            productID: parsed.productID,
            localName: peripheral.name ?? localName,
            rssi: rssi
        )
        continuation.yield(.discovered(id, info))
    }

    fileprivate func handleConnect(peripheral: CBPeripheral) {
        peripheral.delegate = delegate
        if let m = matcherByDevice[peripheral.identifier] {
            peripheral.discoverServices([m.serviceUUID])
        } else {
            peripheral.discoverServices(nil)
        }
        let id = DeviceID(transport: .ble, raw: peripheral.identifier)
        continuation.yield(.connected(id))
    }

    fileprivate func handleDisconnect(peripheral: CBPeripheral, error: Error?) {
        let id = DeviceID(transport: .ble, raw: peripheral.identifier)
        let reason: DisconnectReason = error.map { .error($0.localizedDescription) } ?? .userInitiated
        // Keep peripherals[]/matcherByDevice[] so connect() can be retried without a fresh advertisement.
        inputChars[peripheral.identifier] = nil
        outputChars[peripheral.identifier] = nil
        responseHandles[peripheral.identifier] = nil
        if let pending = pendingResponses.removeValue(forKey: peripheral.identifier) {
            pending.cont.resume(returning: nil)
        }
        continuation.yield(.disconnected(id, reason))
    }

    fileprivate func handleServicesDiscovered(peripheral: CBPeripheral) {
        guard let services = peripheral.services else { return }
        guard let m = matcherByDevice[peripheral.identifier],
              let svc = services.first(where: { $0.uuid == m.serviceUUID }) else { return }
        var chars = [m.inputCharacteristic]
        if let out = m.outputCharacteristic { chars.append(out) }
        for rsp in m.responseCharacteristics { chars.append(rsp.uuid) }
        peripheral.discoverCharacteristics(chars, for: svc)
    }

    fileprivate func handleCharacteristicsDiscovered(peripheral: CBPeripheral, service: CBService) async {
        guard let m = matcherByDevice[peripheral.identifier],
              let chars = service.characteristics else { return }
        guard let inputCh = chars.first(where: { $0.uuid == m.inputCharacteristic }) else { return }
        inputChars[peripheral.identifier] = inputCh
        // Defer the input-report subscription until after init — we don't want a flood of
        // HID reports interleaving with the command handshake.

        var handles: [CBUUID: UInt16] = [:]
        for rsp in m.responseCharacteristics {
            guard let ch = chars.first(where: { $0.uuid == rsp.uuid }) else { continue }
            handles[rsp.uuid] = rsp.handle
            peripheral.setNotifyValue(true, for: ch)
        }
        responseHandles[peripheral.identifier] = handles

        if let outUUID = m.outputCharacteristic,
           let outCh = chars.first(where: { $0.uuid == outUUID }) {
            outputChars[peripheral.identifier] = outCh
        }

        // Give the CCCD writes a moment to land before issuing commands.
        try? await Task.sleep(for: .milliseconds(20))

        let id = DeviceID(transport: .ble, raw: peripheral.identifier)
        for cmd in m.initCommands {
            let resp = (try? await sendAwaitingResponse(cmd, to: id, timeout: .milliseconds(500))) ?? nil
            continuation.yield(.commandResponse(id, request: cmd, response: resp))
        }

        // Init complete — open the input-report firehose.
        peripheral.setNotifyValue(true, for: inputCh)

        continuation.yield(.ready(id))
    }

    fileprivate func handleNotification(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let value = characteristic.value else { return }
        let id = DeviceID(transport: .ble, raw: peripheral.identifier)
        if let inputCh = inputChars[peripheral.identifier], characteristic == inputCh {
            continuation.yield(.reportReceived(id, reportID: nil, value))
            return
        }
        if let handle = responseHandles[peripheral.identifier]?[characteristic.uuid] {
            let frame = CommandResponseFrame(data: value, sourceHandle: handle)
            if let pending = pendingResponses[peripheral.identifier],
               responseMatches(request: pending.request, response: value) {
                pendingResponses.removeValue(forKey: peripheral.identifier)
                pending.cont.resume(returning: frame)
            } else {
                continuation.yield(.unmatchedResponse(id, value, sourceHandle: handle))
            }
        }
    }
}

private final class BLEDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    weak var transport: BLETransport?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { [weak transport] in await transport?.handleStateUpdate(state) }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        Task { [weak transport] in
            await transport?.handleDiscovery(peripheral: peripheral, mfgData: mfg, localName: localName, rssi: rssi)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { [weak transport] in await transport?.handleConnect(peripheral: peripheral) }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { [weak transport] in await transport?.handleDisconnect(peripheral: peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { [weak transport] in await transport?.handleServicesDiscovered(peripheral: peripheral) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { [weak transport] in await transport?.handleCharacteristicsDiscovered(peripheral: peripheral, service: service) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { [weak transport] in await transport?.handleNotification(peripheral: peripheral, characteristic: characteristic) }
    }
}
