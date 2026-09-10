import Foundation

// Serialises every post-.ready sendAwaitingResponse for one device.
// BLETransport keeps a single pending continuation per peripheral and
// preconditions against overlap; CoreHID can deliver set-reports
// concurrently and the LTK pairing exchange can run at any time after
// .ready, so anything that awaits a command response goes through here.
//
// An actor's methods are re-entrant across suspension points, so isolation
// alone doesn't serialise the awaited transport call — each send chains on
// the previous one's task instead. The chained task is unstructured on
// purpose: a cancelled caller must not abandon a BLE command mid-flight.
actor CommandTunnel {
    private let transport: any Transport
    private let deviceID: DeviceID
    private var tail: Task<Void, Never>?

    init(transport: any Transport, deviceID: DeviceID) {
        self.transport = transport
        self.deviceID = deviceID
    }

    func send(_ frame: Data, timeout: Duration) async throws -> CommandResponseFrame? {
        let previous = tail
        let transport = self.transport
        let deviceID = self.deviceID
        let task = Task<CommandResponseFrame?, any Error> {
            await previous?.value
            return try await transport.sendAwaitingResponse(frame, to: deviceID, timeout: timeout)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
