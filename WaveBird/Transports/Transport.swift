import Foundation

protocol Transport: Actor {
    nonisolated var kind: TransportKind { get }
    nonisolated var events: AsyncStream<TransportEvent> { get }

    func startDiscovery(matchers: [TransportMatcher]) async
    func stopDiscovery() async
    func connect(_ id: DeviceID) async throws
    func disconnect(_ id: DeviceID) async
    func send(_ payload: Data, reportID: UInt8?, to id: DeviceID) async throws
    func sendAwaitingResponse(_ payload: Data, to id: DeviceID, timeout: Duration) async throws -> CommandResponseFrame?
    func sendVibration(_ payload: Data, to id: DeviceID) async throws

    // Subscribe/unsubscribe the device's optional secondary input channels to
    // match `reportIDs` (a subset of the matcher's declared `secondaryInputs`).
    // The primary input is always subscribed; secondaries are opt-in per output
    // mode — e.g. only ns2Passthrough wants Pro's Report 0x09 on handle 0x000E.
    // The coordinator calls this when an output mode resolves or changes.
    func setSecondaryInputs(_ reportIDs: Set<UInt8>, for id: DeviceID) async
}

extension Transport {
    func sendAwaitingResponse(_ payload: Data, to id: DeviceID, timeout: Duration) async throws -> CommandResponseFrame? {
        try await send(payload, reportID: nil, to: id)
        return nil
    }

    func sendVibration(_ payload: Data, to id: DeviceID) async throws {}

    func setSecondaryInputs(_ reportIDs: Set<UInt8>, for id: DeviceID) async {}
}
