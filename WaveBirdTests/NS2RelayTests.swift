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

// Count non-overlapping occurrences of `pattern` in `data`.
func occurrences(of pattern: Data, in data: Data) -> Int {
    guard !pattern.isEmpty, data.count >= pattern.count else { return 0 }
    var count = 0
    var i = data.startIndex
    while i <= data.endIndex - pattern.count {
        if data[i..<(i + pattern.count)].elementsEqual(pattern) {
            count += 1
            i += pattern.count
        } else {
            i += 1
        }
    }
    return count
}

struct NS2RelayDescriptorTests {

    // Report ID 0x80 declared as a 64-byte Output; 0x81 as an 80-byte Input.
    private let tunnelOut = Data([0x85, 0x80, 0x09, 0x03, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02])
    private let tunnelIn  = Data([0x85, 0x81, 0x09, 0x04, 0x95, 0x50, 0x81, 0x02])
    private let gamePadHeader = Data([0x05, 0x01, 0x09, 0x05, 0xA1, 0x01])

    @Test func tunnelBlockIsOnTheVendorPageAndDeclaresBothReports() {
        let block = VirtualHIDDevice.ns2TunnelDescriptorBlock
        #expect(block.prefix(3) == Data([0x06, 0x00, 0xFF]))  // Usage Page 0xFF00
        #expect(occurrences(of: tunnelOut, in: block) == 1)
        #expect(occurrences(of: tunnelIn, in: block) == 1)
    }

    @Test func proDescriptorIsRealUSBShapePlusOneTunnelBlock() {
        let d = ProControllerProfile().relayDescriptor
        #expect(d.prefix(6) == gamePadHeader)
        #expect(d.last == 0xC0)
        #expect(occurrences(of: VirtualHIDDevice.ns2TunnelDescriptorBlock, in: d) == 1)
        // Real Pro report set: 0x05 in, 0x09 in, 0x02 out — each declared once.
        #expect(occurrences(of: Data([0x85, 0x05]), in: d) == 1)
        #expect(occurrences(of: Data([0x85, 0x09]), in: d) == 1)
        #expect(occurrences(of: Data([0x85, 0x02, 0x09, 0x01, 0x95, 0x3F, 0x91, 0x02]), in: d) == 1)
        // The tunnel block sits inside the application collection.
        #expect(d.dropLast().suffix(VirtualHIDDevice.ns2TunnelDescriptorBlock.count) == VirtualHIDDevice.ns2TunnelDescriptorBlock)
    }

    @Test func gameCubeDescriptorDeclaresGamePadInput05Rumble03AndTunnel() {
        let d = GameCubeProfile().relayDescriptor
        #expect(d.prefix(6) == gamePadHeader)
        #expect(d.last == 0xC0)
        #expect(occurrences(of: Data([0x85, 0x05, 0x09, 0x01, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x3F, 0x81, 0x02]), in: d) == 1)
        #expect(occurrences(of: Data([0x85, 0x03, 0x09, 0x02, 0x95, 0x3F, 0x91, 0x02]), in: d) == 1)
        #expect(occurrences(of: VirtualHIDDevice.ns2TunnelDescriptorBlock, in: d) == 1)
    }

    @Test func joyConDescriptorsDeclareRumble01() {
        for side in [JoyConProfile.Side.left, .right] {
            let d = JoyConProfile(side: side).relayDescriptor
            #expect(d.prefix(6) == gamePadHeader)
            #expect(occurrences(of: Data([0x85, 0x01, 0x09, 0x02, 0x95, 0x3F, 0x91, 0x02]), in: d) == 1)
            #expect(occurrences(of: VirtualHIDDevice.ns2TunnelDescriptorBlock, in: d) == 1)
        }
    }

    @Test func relayDescriptorEmbedsTheGivenRumbleID() {
        let d = VirtualHIDDevice.ns2RelayDescriptor(rumbleOutputReportID: 0x7A)
        #expect(occurrences(of: Data([0x85, 0x7A, 0x09, 0x02, 0x95, 0x3F, 0x91, 0x02]), in: d) == 1)
        #expect(occurrences(of: Data([0x85, 0x05]), in: d) == 1)
        #expect(d.first == 0x05 && d.last == 0xC0)
    }
}
