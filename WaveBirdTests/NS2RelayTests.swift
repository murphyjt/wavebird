import CoreHID
import Foundation
import Testing
@testable import WaveBird

// Minimal Transport that records overlap. `Transport` is WaveBird's own
// protocol (not an OS type), so a fake here doesn't violate the no-mocking
// rule in CLAUDE.md — it exists only to prove the tunnel serialises.
actor OverlapRecordingTransport: Transport {
    nonisolated let kind: TransportKind = .ble
    nonisolated let events: AsyncStream<TransportEvent> = AsyncStream { _ in }

    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var order: [UInt8] = []

    func startDiscovery(matchers: [TransportMatcher]) async {}
    func stopDiscovery() async {}
    func connect(_ id: DeviceID) async throws {}
    func disconnect(_ id: DeviceID) async {}
    func send(_ payload: Data, reportID: UInt8?, to id: DeviceID) async throws {}

    func sendAwaitingResponse(_ payload: Data, to id: DeviceID, timeout: Duration) async throws -> CommandResponseFrame? {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        order.append(payload[payload.startIndex])
        try? await Task.sleep(for: .milliseconds(20))
        inFlight -= 1
        return CommandResponseFrame(data: Data([payload[payload.startIndex], 0x01, 0x01, 0x00, 0x10, 0x78]), sourceHandle: 0x001A)
    }
}

struct CommandTunnelTests {

    @Test func concurrentSendsNeverOverlapAndKeepOrder() async throws {
        let transport = OverlapRecordingTransport()
        let id = DeviceID(transport: .ble, raw: UUID())
        let tunnel = CommandTunnel(transport: transport, deviceID: id)

        // Fire five sends without awaiting between them, then collect.
        let results = try await withThrowingTaskGroup(of: (UInt8, UInt8?).self) { group in
            for cmd: UInt8 in [1, 2, 3, 4, 5] {
                group.addTask {
                    let r = try await tunnel.send(Data([cmd, 0x91, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]), timeout: .seconds(1))
                    return (cmd, r?.data.first)
                }
                // A tiny stagger so the submission order is deterministic.
                try await Task.sleep(for: .milliseconds(1))
            }
            var out: [(UInt8, UInt8?)] = []
            for try await r in group { out.append(r) }
            return out
        }

        #expect(await transport.maxInFlight == 1)
        #expect(await transport.order == [1, 2, 3, 4, 5])
        // Every caller got its own response, not a neighbour's.
        for (cmd, echoed) in results { #expect(echoed == cmd) }
    }
}
