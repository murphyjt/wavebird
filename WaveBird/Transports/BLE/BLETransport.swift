@preconcurrency import CoreBluetooth
import Foundation

enum BLETransportError: Error {
    case wrongTransport
    case unknownDevice
    case disconnected
    case writeQueueFull
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
    private var pendingResponses: [UUID: (token: UUID, request: Data, cont: CheckedContinuation<CommandResponseFrame?, Never>)] = [:]
    // Single-slot coalescing queue for vibration writes that hit backpressure.
    // CoreBluetooth silently drops writeWithoutResponse calls when the per-peripheral
    // queue is full, so we stash the latest pending payload here and drain it from
    // peripheralIsReady. Rumble is naturally coalescable — the freshest frame wins.
    private var pendingVibration: [UUID: Data] = [:]

    private enum InputMode {
        case common
        case console
        case restoringCommon
    }

    private struct Session {
        let token = UUID()
        let started = ContinuousClock.now
        var mode: InputMode = .common
        var commonInputSeen = false
        var deferredCommonCommands: ArraySlice<Data> = []
        var ready = false
        var reports = 0
        var lastLog = ContinuousClock.now
        var lastInput = ContinuousClock.now
        var signature: InputSignature?
    }
    private var sessions: [UUID: Session] = [:]
    private var consoleInputs: [UUID: CBCharacteristic] = [:]
    private var consoleOutputs: [UUID: CBCharacteristic] = [:]
    private var sessionStarts: [UUID: CBCharacteristic] = [:]
    private var descriptorsDiscovered: Set<UUID> = []
    private let sessionServiceUUID = CBUUID(string: "00c5af5d-1964-4e30-8f51-1956f96bd280")
    private let reportRateUUID = CBUUID(string: "679d5510-5a24-4dee-9557-95df80486ecb")

    private func diagnostic(_ peripheral: CBPeripheral, _ message: String) {
        stderrLog("[nyxi][\(peripheral.identifier)][\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(message)")
    }

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
        let console = sessions[id.raw]?.mode == .console
        guard let p = peripherals[id.raw],
              let ch = console ? consoleOutputs[id.raw] : outputChars[id.raw] else {
            throw BLETransportError.unknownDevice
        }
        let wire = console ? NS2Console.frame(payload) : payload
        p.writeValue(wire, for: ch, type: writeType(for: ch))
    }

    func sendVibration(_ payload: Data, to id: DeviceID) async throws {
        guard sessions[id.raw]?.mode == .common,
              let p = peripherals[id.raw], let ch = vibrationChars[id.raw] else { return }
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
        guard sessions[id.raw]?.mode == .common,
              let p = peripherals[id.raw], let available = secondaryChars[id.raw] else { return }
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
        let console = sessions[id.raw]?.mode == .console
        guard let p = peripherals[id.raw],
              let ch = console ? consoleOutputs[id.raw] : outputChars[id.raw] else {
            throw BLETransportError.unknownDevice
        }
        let generation = sessions[id.raw]?.token
        let wire = console ? NS2Console.frame(payload) : payload
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while writeType(for: ch) == .withoutResponse, !p.canSendWriteWithoutResponse {
            guard p.state == .connected, sessions[id.raw]?.token == generation else {
                throw BLETransportError.disconnected
            }
            if console, sessions[id.raw]?.commonInputSeen == true { return nil }
            guard ContinuousClock.now < deadline else { throw BLETransportError.writeQueueFull }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard p.state == .connected, sessions[id.raw]?.token == generation else {
            throw BLETransportError.disconnected
        }
        if console, sessions[id.raw]?.commonInputSeen == true { return nil }
        guard responseHandles[id.raw]?.isEmpty == false else {
            p.writeValue(wire, for: ch, type: writeType(for: ch))
            return nil
        }
        precondition(pendingResponses[id.raw] == nil, "overlapping sendAwaitingResponse for \(id.raw)")
        let token = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandResponseFrame?, Never>) in
            pendingResponses[id.raw] = (token: token, request: payload, cont: cont)
            p.writeValue(wire, for: ch, type: writeType(for: ch))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expirePending(id: id.raw, token: token)
            }
        }
    }

    private func expirePending(id: UUID, token: UUID) {
        guard pendingResponses[id]?.token == token,
              let pending = pendingResponses.removeValue(forKey: id) else { return }
        pending.cont.resume(returning: nil)
    }

    private nonisolated func writeType(for ch: CBCharacteristic) -> CBCharacteristicWriteType {
        ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
    }

    fileprivate func handleStateUpdate(_ state: CBManagerState) {
        stderrLog("[ble] Bluetooth state=\(stateName(state))")
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
        diagnostic(peripheral, "advertisement PID=\(String(format: "%04X", parsed.productID)) RSSI=\(rssi) name=\(localName ?? "-") mfg=\(mfg.map { String(format: "%02X", $0) }.joined())")
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
        sessions[peripheral.identifier] = Session()
        diagnostic(peripheral, "connected; discovering GATT")
        peripheral.delegate = delegate
        if let m = matcherByDevice[peripheral.identifier] {
            peripheral.discoverServices(JoyConPairProfile.isJoyCon(productID: m.productID)
                ? [m.serviceUUID, sessionServiceUUID] : [m.serviceUUID])
        } else {
            peripheral.discoverServices(nil)
        }
        let id = DeviceID(transport: .ble, raw: peripheral.identifier)
        continuation.yield(.connected(id))
    }

    fileprivate func handleDisconnect(peripheral: CBPeripheral, error: Error?) {
        let id = DeviceID(transport: .ble, raw: peripheral.identifier)
        diagnostic(peripheral, "disconnected reports=\(sessions[peripheral.identifier]?.reports ?? 0) error=\(String(describing: error))")
        sessions[peripheral.identifier] = nil
        consoleInputs[peripheral.identifier] = nil
        consoleOutputs[peripheral.identifier] = nil
        sessionStarts[peripheral.identifier] = nil
        descriptorsDiscovered.remove(peripheral.identifier)
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
        if JoyConPairProfile.isJoyCon(productID: m.productID),
           let sessionService = services.first(where: { $0.uuid == sessionServiceUUID }) {
            peripheral.discoverCharacteristics([NS2Handle.uuid(5, for: .joyConL)!], for: sessionService)
        }
        var chars = [m.inputCharacteristic]
        if let out = m.outputCharacteristic { chars.append(out) }
        if let vib = m.vibrationCharacteristic { chars.append(vib) }
        for rsp in m.responseCharacteristics { chars.append(rsp.uuid) }
        for extra in m.secondaryInputs { chars.append(extra.uuid) }
        if JoyConPairProfile.isJoyCon(productID: m.productID) {
            let type: NS2ControllerType = m.productID == 0x2067 ? .joyConL : .joyConR
            chars += [NS2Handle.uuid(NS2Handle.commandWrite, for: type)!,
                      NS2Handle.uuid(NS2Handle.inputReportVariant, for: type)!]
        }
        peripheral.discoverCharacteristics(Array(Set(chars)), for: svc)
    }

    fileprivate func handleCharacteristicsDiscovered(peripheral: CBPeripheral, service: CBService) async {
        guard let m = matcherByDevice[peripheral.identifier],
              let chars = service.characteristics else { return }
        if service.uuid == sessionServiceUUID {
            sessionStarts[peripheral.identifier] = chars.first { $0.uuid == NS2Handle.uuid(5, for: .joyConL) }
            return
        }
        guard service.uuid == m.serviceUUID else { return }
        guard let generation = sessions[peripheral.identifier]?.token else { return }
        diagnostic(peripheral, "GATT " + chars.map { "\($0.uuid):\($0.properties.rawValue)" }.joined(separator: " "))
        if JoyConPairProfile.isJoyCon(productID: m.productID) {
            let type: NS2ControllerType = m.productID == 0x2067 ? .joyConL : .joyConR
            consoleInputs[peripheral.identifier] = chars.first { $0.uuid == NS2Handle.uuid(NS2Handle.inputReportVariant, for: type) }
            consoleOutputs[peripheral.identifier] = chars.first { $0.uuid == NS2Handle.uuid(NS2Handle.commandWrite, for: type) }
        }
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

        let key = peripheral.identifier
        let id = DeviceID(transport: .ble, raw: key)
        var replies = 0
        for (index, cmd) in m.initCommands.enumerated() {
            guard sessions[key]?.token == generation else { return }
            let resp = (try? await sendAwaitingResponse(cmd, to: id, timeout: .milliseconds(500))) ?? nil
            guard sessions[key]?.token == generation else { return }
            if resp != nil { replies += 1 }
            continuation.yield(.commandResponse(id, request: cmd, response: resp))
            // Probe input after two unanswered commands. Resume the rest of
            // the Nintendo handshake if common input arrives, even after fallback.
            if index == 1, replies == 0, consoleOutputs[key] != nil {
                sessions[key]?.deferredCommonCommands = m.initCommands.dropFirst(index + 1)
                break
            }
        }
        guard sessions[key]?.token == generation else { return }

        // Subscribe now so input can decide whether to resume the common handshake.
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

        if consoleOutputs[key] != nil {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(1500))
            while sessions[key]?.token == generation, sessions[key]?.commonInputSeen == false,
                  ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard sessions[key]?.token == generation else { return }
            if sessions[key]?.commonInputSeen == false {
                await startConsole(peripheral, generation: generation)
                // This task owns the handoff during startup, so the last
                // console exchange can finish before any common command starts.
                guard sessions[key]?.commonInputSeen == true, sessions[key]?.ready == false else { return }
            }
        }
        await finishCommonInitialization(peripheral, generation: generation)
    }

    private func finishCommonInitialization(_ peripheral: CBPeripheral, generation: UUID) async {
        let key = peripheral.identifier
        guard let session = sessions[key], session.token == generation else { return }
        let id = DeviceID(transport: .ble, raw: key)
        let restoring = session.mode == .console
        if restoring {
            sessions[key]?.mode = .restoringCommon
            if let consoleInput = consoleInputs[key] {
                peripheral.setNotifyValue(false, for: consoleInput)
            }
            diagnostic(peripheral, "late common input; returning to Nintendo path")
        }
        var responses: [CommandExchange] = []
        for cmd in session.deferredCommonCommands {
            let response = (try? await sendAwaitingResponse(cmd, to: id, timeout: .milliseconds(500))) ?? nil
            guard sessions[key]?.token == generation else { return }
            responses.append(CommandExchange(request: cmd, response: response))
        }
        sessions[key]?.deferredCommonCommands = []
        sessions[key]?.mode = .common
        if restoring {
            // Apply the restored identity and fresh metadata together before
            // forwarding common reports or allowing an LTK pairing prompt.
            continuation.yield(.commonModeRestored(id, responses: responses))
        } else {
            for exchange in responses {
                continuation.yield(.commandResponse(id, request: exchange.request, response: exchange.response))
            }
        }
        markReady(peripheral)
    }

    private func markReady(_ peripheral: CBPeripheral) {
        guard sessions[peripheral.identifier]?.ready == false else { return }
        sessions[peripheral.identifier]?.ready = true
        diagnostic(peripheral, "ready mode=\(sessions[peripheral.identifier]?.mode == .console ? "console" : "common")")
        continuation.yield(.ready(DeviceID(transport: .ble, raw: peripheral.identifier)))
    }

    private func startConsole(_ peripheral: CBPeripheral, generation: UUID) async {
        let key = peripheral.identifier
        guard sessions[key]?.token == generation, sessions[key]?.commonInputSeen == false else { return }
        guard let input = consoleInputs[key], consoleOutputs[key] != nil,
              let start = sessionStarts[key] else {
            diagnostic(peripheral, "console GATT incomplete (session-start service or side channels missing)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        let id = DeviceID(transport: .ble, raw: key)
        sessions[key]?.mode = .console
        diagnostic(peripheral, "no common input after 1.5s; starting experimental console channel")
        continuation.yield(.consoleMode(id))
        peripheral.writeValue(Data([1, 0]), for: start, type: writeType(for: start))
        // Command-response subscriptions were started before the common probe.
        for uuid in responseHandles[key]?.keys ?? Dictionary<CBUUID, UInt16>().keys {
            if let ch = peripheral.services?.flatMap({ $0.characteristics ?? [] }).first(where: { $0.uuid == uuid }) {
                guard await waitForNotify(ch, peripheral: peripheral, generation: generation) else { return }
            }
        }
        for cmd in NS2Console.initCommands {
            guard isStartingConsole(key, generation: generation) else { return }
            let response: CommandResponseFrame?
            do {
                response = try await sendAwaitingResponse(cmd, to: id, timeout: .milliseconds(700))
            } catch {
                guard isStartingConsole(key, generation: generation) else { return }
                diagnostic(peripheral, "console write failed: \(error)")
                central.cancelPeripheralConnection(peripheral)
                return
            }
            guard isStartingConsole(key, generation: generation) else { return }
            diagnostic(peripheral, "console cmd=\(String(format: "%02X/%02X", cmd[0], cmd[3])) reply=\(response?.data.count ?? 0) bytes")
            continuation.yield(.commandResponse(id, request: cmd, response: response))
        }
        guard isStartingConsole(key, generation: generation) else { return }
        peripheral.discoverDescriptors(for: input)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !descriptorsDiscovered.contains(key), isStartingConsole(key, generation: generation),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard isStartingConsole(key, generation: generation) else { return }
        if let rate = input.descriptors?.first(where: { $0.uuid == reportRateUUID }) {
            peripheral.writeValue(Data([0x85, 0]), for: rate)
            // CoreBluetooth serializes descriptor writes and the following CCCD.
            diagnostic(peripheral, "report-rate descriptor: 85 00")
        } else {
            diagnostic(peripheral, "report-rate descriptor missing; trying default interval")
        }
        peripheral.setNotifyValue(true, for: input)
        guard await waitForNotify(input, peripheral: peripheral, generation: generation),
              isStartingConsole(key, generation: generation) else { return }
        markReady(peripheral)
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, await self.checkInputHealth(peripheral, generation: generation) else { return }
            }
        }
    }

    private func isStartingConsole(_ key: UUID, generation: UUID) -> Bool {
        guard let session = sessions[key], session.token == generation else { return false }
        return session.mode == .console && !session.commonInputSeen
    }

    private func waitForNotify(_ ch: CBCharacteristic, peripheral: CBPeripheral, generation: UUID) async -> Bool {
        let key = peripheral.identifier
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while isStartingConsole(key, generation: generation), !ch.isNotifying,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard isStartingConsole(key, generation: generation) else { return false }
        guard ch.isNotifying else {
            diagnostic(peripheral, "notification subscription failed: \(ch.uuid)")
            central.cancelPeripheralConnection(peripheral)
            return false
        }
        return true
    }

    private func checkInputHealth(_ peripheral: CBPeripheral, generation: UUID) -> Bool {
        guard let session = sessions[peripheral.identifier], session.token == generation,
              session.mode == .console else { return false }
        diagnostic(peripheral, "health age=\(session.started.duration(to: .now)) reports=\(session.reports) lastInput=\(session.lastInput.duration(to: .now))")
        return true
    }

    private func logInput(_ peripheral: CBPeripheral, data: Data, raw: Data) {
        guard var session = sessions[peripheral.identifier],
              let matcher = matcherByDevice[peripheral.identifier],
              JoyConPairProfile.isJoyCon(productID: matcher.productID) else { return }
        let profile = JoyConProfile(side: matcher.productID == 0x2067 ? .left : .right)
        guard let state = profile.parseBLEReport(data, calibration: ControllerCalibration()) else { return }
        session.reports += 1
        session.lastInput = .now
        let sig = state.idleSignature
        let buttonsChanged = session.signature?.buttons != sig.buttons
        if session.reports <= 3 || buttonsChanged || (session.signature != sig && session.lastLog.duration(to: .now) > .milliseconds(100)) {
            diagnostic(peripheral, "input #\(session.reports) mode=\(session.mode == .console ? "console" : "common") buttons=\(String(format: "%08X", state.buttons.rawValue)) L=\(state.leftStick) R=\(state.rightStick) raw=\(raw.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))")
            session.lastLog = .now
        }
        session.signature = sig
        sessions[peripheral.identifier] = session
    }

    fileprivate func handleDescriptors(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if characteristic == consoleInputs[peripheral.identifier] {
            descriptorsDiscovered.insert(peripheral.identifier)
        }
        diagnostic(peripheral, "descriptors \(characteristic.uuid) error=\(String(describing: error))")
    }

    fileprivate func handleGATTError(_ peripheral: CBPeripheral, operation: String, error: Error?) {
        diagnostic(peripheral, "\(operation) error=\(String(describing: error))")
    }

    fileprivate func handleNotification(peripheral: CBPeripheral, characteristic: CBCharacteristic) async {
        guard let value = characteristic.value else { return }
        let key = peripheral.identifier
        let id = DeviceID(transport: .ble, raw: key)
        guard let session = sessions[key] else { return }
        if characteristic == inputChars[key] {
            guard value.count >= 62 else { return }
            if !session.commonInputSeen {
                sessions[key]?.commonInputSeen = true
                if session.mode == .console, session.ready {
                    await finishCommonInitialization(peripheral, generation: session.token)
                    return
                }
            }
            guard session.mode == .common, session.ready else { return }
            logInput(peripheral, data: value, raw: value)
            continuation.yield(.reportReceived(id, reportID: nil, value))
            return
        }
        if characteristic == consoleInputs[key] {
            guard session.mode == .console, !session.commonInputSeen, session.ready,
                  let report = NS2Console.sharedReport(value, left: matcherByDevice[key]?.productID == 0x2067)
            else { return }
            logInput(peripheral, data: report, raw: value)
            continuation.yield(.reportReceived(id, reportID: nil, report))
            return
        }
        if let rid = secondaryInputs[key]?[characteristic.uuid] {
            continuation.yield(.reportReceived(id, reportID: rid, value))
            return
        }
        if let handle = responseHandles[key]?[characteristic.uuid] {
            if let pending = pendingResponses[key],
               let normalized = NS2Console.reply(value, to: pending.request, console: session.mode == .console) {
                let frame = CommandResponseFrame(data: normalized, sourceHandle: handle)
                pendingResponses.removeValue(forKey: key)
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
        Task { [weak transport] in
            if let error { await transport?.handleGATTError(peripheral, operation: "services", error: error); return }
            await transport?.handleServicesDiscovered(peripheral: peripheral)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { [weak transport] in
            if let error { await transport?.handleGATTError(peripheral, operation: "characteristics", error: error); return }
            await transport?.handleCharacteristicsDiscovered(peripheral: peripheral, service: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { [weak transport] in
            if let error { await transport?.handleGATTError(peripheral, operation: "input \(characteristic.uuid)", error: error); return }
            await transport?.handleNotification(peripheral: peripheral, characteristic: characteristic)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { [weak transport] in await transport?.handleDisconnect(peripheral: peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        Task { [weak transport] in await transport?.handleDescriptors(peripheral, characteristic: characteristic, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { [weak transport] in await transport?.handleGATTError(peripheral, operation: "notify \(characteristic.uuid) enabled=\(characteristic.isNotifying)", error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        Task { [weak transport] in await transport?.handleGATTError(peripheral, operation: "descriptor write \(descriptor.uuid)", error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            Task { [weak transport] in await transport?.handleGATTError(peripheral, operation: "write \(characteristic.uuid)", error: error) }
        }
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
