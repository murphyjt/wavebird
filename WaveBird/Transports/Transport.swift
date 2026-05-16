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
}

extension Transport {
    func sendAwaitingResponse(_ payload: Data, to id: DeviceID, timeout: Duration) async throws -> CommandResponseFrame? {
        try await send(payload, reportID: nil, to: id)
        return nil
    }

    func sendVibration(_ payload: Data, to id: DeviceID) async throws {}
}
