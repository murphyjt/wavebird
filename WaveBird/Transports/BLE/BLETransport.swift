@preconcurrency import CoreBluetooth
import Foundation

nonisolated enum BLETransportError: Error {
    case wrongTransport
    case unknownDevice
}

actor BLETransport: Transport {
    nonisolated let kind: TransportKind = .ble
    nonisolated let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let queue: DispatchQueue
    private let central: CBCentralManager
    private let delegate: BLEDelegate

    private var matchers: [BLEMatcher] = []
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var matcherByDevice: [UUID: BLEMatcher] = [:]
    private var inputChars: [UUID: CBCharacteristic] = [:]
    private var outputChars: [UUID: CBCharacteristic] = [:]

    init() {
        let (stream, cont) = AsyncStream.makeStream(of: TransportEvent.self)
        let q = DispatchQueue(label: "wavebird.ble", qos: .userInitiated)
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
        guard central.state == .poweredOn else { return }
        let services = ble.map(\.serviceUUID)
        central.scanForPeripherals(
            withServices: services.isEmpty ? nil : services,
            options: nil
        )
    }

    func stopDiscovery() async {
        guard central.state == .poweredOn else { return }
        central.stopScan()
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
        let writeType: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(payload, for: ch, type: writeType)
    }

    fileprivate func handleStateUpdate(_ state: CBManagerState) {
        if state != .poweredOn {
            continuation.yield(.error(nil, "BLE state: \(state.rawValue)"))
        }
    }

    fileprivate func handleDiscovery(
        peripheral: CBPeripheral,
        mfgData: Data?,
        localName: String?,
        rssi: Int
    ) {
        guard let mfg = mfgData,
              let parsed = BLEAdvertisementDecoder.decodeNintendoMfgData(mfg) else { return }
        let matcher = matchers.first { $0.productID == parsed.productID }
        let accept = matchers.isEmpty ? parsed.vendorID == 0x057E : (matcher != nil)
        guard accept else { return }
        peripherals[peripheral.identifier] = peripheral
        if let m = matcher { matcherByDevice[peripheral.identifier] = m }
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
        peripherals[peripheral.identifier] = nil
        inputChars[peripheral.identifier] = nil
        outputChars[peripheral.identifier] = nil
        matcherByDevice[peripheral.identifier] = nil
        continuation.yield(.disconnected(id, reason))
    }

    fileprivate func handleServicesDiscovered(peripheral: CBPeripheral) {
        guard let services = peripheral.services else { return }
        guard let m = matcherByDevice[peripheral.identifier],
              let svc = services.first(where: { $0.uuid == m.serviceUUID }) else { return }
        var chars = [m.inputCharacteristic]
        if let out = m.outputCharacteristic { chars.append(out) }
        peripheral.discoverCharacteristics(chars, for: svc)
    }

    fileprivate func handleCharacteristicsDiscovered(peripheral: CBPeripheral, service: CBService) {
        guard let m = matcherByDevice[peripheral.identifier],
              let chars = service.characteristics else { return }
        if let inputCh = chars.first(where: { $0.uuid == m.inputCharacteristic }) {
            inputChars[peripheral.identifier] = inputCh
            peripheral.setNotifyValue(true, for: inputCh)
        }
        if let outUUID = m.outputCharacteristic,
           let outCh = chars.first(where: { $0.uuid == outUUID }) {
            outputChars[peripheral.identifier] = outCh
        }
    }

    fileprivate func handleNotification(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let value = characteristic.value else { return }
        guard let inputCh = inputChars[peripheral.identifier],
              characteristic == inputCh else { return }
        let id = DeviceID(transport: .ble, raw: peripheral.identifier)
        continuation.yield(.reportReceived(id, value))
    }
}

private nonisolated final class BLEDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
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
