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

    // Run the actor on the same dispatch queue as the CB delegate so that calls
    // into CBPeripheral / CBCentralManager (writeValue, canSendWriteWithoutResponse,
    // …) all execute from the manager's queue without sync hops to main. Before this,
    // CB had to marshal every off-queue access back to its main-queue delegate, which
    // contended with input notifications (also on main) and starved the @MainActor
    // consumer of run loop time — visible as input lag and Hz spikes.
    nonisolated let unownedExecutor: UnownedSerialExecutor
    private let executor: BLESerialExecutor

    private let queue: DispatchQueue
    private let central: CBCentralManager
    private let delegate: BLEDelegate

    private var matchers: [BLEMatcher] = []
    private var wantsScan: Bool = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var matcherByDevice: [UUID: BLEMatcher] = [:]
    private var inputChars: [UUID: CBCharacteristic] = [:]
    // Per-peripheral additional input chars → their HID report ID. Used by the
    // ns2Passthrough path to forward extra Nintendo input reports (e.g. Pro's
    // Report 0x09 on handle 0x000E) verbatim under the right report ID. Populated
    // at characteristic discovery so notifications can be tagged, but NOT
    // subscribed there — secondaries are opt-in per output mode (setSecondaryInputs).
    private var secondaryInputs: [UUID: [CBUUID: UInt8]] = [:]
    // Per-peripheral report ID → its discovered secondary characteristic, so a
    // later setSecondaryInputs can toggle notifications without re-discovering.
    private var secondaryChars: [UUID: [UInt8: CBCharacteristic]] = [:]
    // Report IDs currently subscribed per peripheral. Diffed against the
    // requested set so setSecondaryInputs only flips characteristics that change.
    private var subscribedSecondaries: [UUID: Set<UInt8>] = [:]
    private var outputChars: [UUID: CBCharacteristic] = [:]
    private var vibrationChars: [UUID: CBCharacteristic] = [:]
    // Per device, a map of subscribed response-char UUID → its handle.
    private var responseHandles: [UUID: [CBUUID: UInt16]] = [:]
    private var pendingResponses: [UUID: (request: Data, cont: CheckedContinuation<CommandResponseFrame?, Never>)] = [:]
    // Single-slot coalescing queue for vibration writes that hit backpressure.
    // CoreBluetooth silently drops writeWithoutResponse calls when the per-peripheral
    // queue is full, so we stash the latest pending payload here and drain it from
    // peripheralIsReady. Rumble is naturally coalescable — the freshest frame wins.
    private var pendingVibration: [UUID: Data] = [:]

    init() {
        // bufferingNewest caps memory if the main-actor consumer falls behind.
        // 64 is well above the ~70 Hz BLE report rate so a healthy consumer
        // never drops events; if the main actor blocks long enough to overflow,
        // dropping the oldest is the right tradeoff for a real-time bridge.
        let (stream, cont) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(64))
        let q = DispatchQueue(label: "WaveBird.BLE", qos: .userInteractive)
        let exec = BLESerialExecutor(queue: q)
        let d = BLEDelegate()
        let c = CBCentralManager(delegate: d, queue: q)
        self.events = stream
        self.continuation = cont
        self.queue = q
        self.executor = exec
        self.unownedExecutor = exec.asUnownedSerialExecutor()
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

    func sendVibration(_ payload: Data, to id: DeviceID) async throws {
        guard let p = peripherals[id.raw], let ch = vibrationChars[id.raw] else { return }
        // For writeWithoutResponse, CoreBluetooth's per-peripheral queue can fill.
        // If it has space, write through; otherwise stash for drain on the
        // peripheralIsReady callback. Newest payload replaces any older pending one.
        if writeType(for: ch) == .withoutResponse, !p.canSendWriteWithoutResponse {
            pendingVibration[id.raw] = payload
            return
        }
        p.writeValue(payload, for: ch, type: writeType(for: ch))
    }

    func setSecondaryInputs(_ reportIDs: Set<UInt8>, for id: DeviceID) async {
        guard let p = peripherals[id.raw], let available = secondaryChars[id.raw] else { return }
        let wanted = reportIDs.intersection(available.keys)
        let current = subscribedSecondaries[id.raw] ?? []
        guard wanted != current else { return }
        for (rid, ch) in available {
            let shouldSubscribe = wanted.contains(rid)
            guard shouldSubscribe != current.contains(rid) else { continue }
            p.setNotifyValue(shouldSubscribe, for: ch)
        }
        subscribedSecondaries[id.raw] = wanted
    }

    fileprivate func handlePeripheralReady(peripheral: CBPeripheral) {
        guard let payload = pendingVibration.removeValue(forKey: peripheral.identifier),
              let ch = vibrationChars[peripheral.identifier] else { return }
        // canSendWriteWithoutResponse can flip back to false between the callback
        // and our write. If it does, re-stash and wait for the next ready event.
        if writeType(for: ch) == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
            pendingVibration[peripheral.identifier] = payload
            return
        }
        peripheral.writeValue(payload, for: ch, type: writeType(for: ch))
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
        // .unknown is the initial state before CB has settled — defer to the
        // next transition rather than briefly flashing an unavailable UI.
        if state != .unknown {
            continuation.yield(.availability(reason: availabilityReason(state)))
        }
        startScanIfReady()
    }

    private func availabilityReason(_ state: CBManagerState) -> String? {
        switch state {
        case .poweredOn: nil
        case .poweredOff: "Bluetooth is off"
        case .resetting: "Bluetooth is resetting…"
        case .unsupported: "Bluetooth is not supported on this Mac"
        case .unauthorized: "WaveBird doesn't have permission to use Bluetooth"
        case .unknown: nil
        @unknown default: "Bluetooth is unavailable"
        }
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
        secondaryInputs[peripheral.identifier] = nil
        secondaryChars[peripheral.identifier] = nil
        subscribedSecondaries[peripheral.identifier] = nil
        outputChars[peripheral.identifier] = nil
        vibrationChars[peripheral.identifier] = nil
        responseHandles[peripheral.identifier] = nil
        pendingVibration[peripheral.identifier] = nil
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
        if let vib = m.vibrationCharacteristic { chars.append(vib) }
        for rsp in m.responseCharacteristics { chars.append(rsp.uuid) }
        for extra in m.secondaryInputs { chars.append(extra.uuid) }
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

        if let vibUUID = m.vibrationCharacteristic,
           let vibCh = chars.first(where: { $0.uuid == vibUUID }) {
            vibrationChars[peripheral.identifier] = vibCh
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

        // Cache any secondary input characteristics (e.g. Pro's Report 0x09) and
        // their HID report IDs, but DON'T subscribe — secondaries are opt-in per
        // output mode. setSecondaryInputs flips notifications on once the
        // coordinator resolves a mode that consumes them (ns2Passthrough).
        var extras: [CBUUID: UInt8] = [:]
        var extraChars: [UInt8: CBCharacteristic] = [:]
        for extra in m.secondaryInputs {
            guard let ch = chars.first(where: { $0.uuid == extra.uuid }) else { continue }
            extras[extra.uuid] = extra.reportID
            extraChars[extra.reportID] = ch
        }
        secondaryInputs[peripheral.identifier] = extras
        secondaryChars[peripheral.identifier] = extraChars
        subscribedSecondaries[peripheral.identifier] = []

        continuation.yield(.ready(id))
    }

    fileprivate func handleNotification(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let value = characteristic.value else { return }
        let id = DeviceID(transport: .ble, raw: peripheral.identifier)
        if let inputCh = inputChars[peripheral.identifier], characteristic == inputCh {
            continuation.yield(.reportReceived(id, reportID: nil, value))
            return
        }
        if let rid = secondaryInputs[peripheral.identifier]?[characteristic.uuid] {
            continuation.yield(.reportReceived(id, reportID: rid, value))
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

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { [weak transport] in await transport?.handlePeripheralReady(peripheral: peripheral) }
    }
}

// Serial executor that runs the BLE actor's work on the CBCentralManager's
// delegate queue. Apple's CoreBluetooth requires CB property/method access from
// the manager's queue; before this, off-queue calls forced internal sync hops
// to main, contending with the @MainActor consumer.
private final class BLESerialExecutor: SerialExecutor, @unchecked Sendable {
    private let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let exec = asUnownedSerialExecutor()
        queue.async {
            unowned.runSynchronously(on: exec)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
