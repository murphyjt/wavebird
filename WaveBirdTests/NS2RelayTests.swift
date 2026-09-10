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

struct NS2RelayTransformTests {

    private let pro = NS2RelayOutput(profile: ProControllerProfile())
    private let gc = NS2RelayOutput(profile: GameCubeProfile())
    private let jcL = NS2RelayOutput(profile: JoyConProfile(side: .left))
    private let jcR = NS2RelayOutput(profile: JoyConProfile(side: .right))

    // CoreHID hands the set-report handler the on-wire frame with the report
    // ID at index 0 (see DualSenseOutput.parseRumble offsets). Build one.
    private func setReport(_ id: UInt8, _ body: [UInt8], paddedTo total: Int) -> Data {
        var d = Data([id] + body)
        if d.count < total { d.append(Data(repeating: 0, count: total - d.count)) }
        return d
    }

    // MARK: identity

    @Test func identityIsTheRealNS2Controller() {
        #expect(pro.vendorID == 0x057E && pro.productID == 0x2069)
        #expect(gc.productID == 0x2073)
        #expect(jcL.productID == 0x2067 && jcR.productID == 0x2066)
        #expect(pro.manufacturer == "Nintendo")
        #expect(pro.descriptor == ProControllerProfile().relayDescriptor)
        #expect(pro.requiredSecondaryReportIDs.isEmpty)   // never subscribe Pro's 0x000E
    }

    // MARK: input 0x05

    @Test func bleFrameBecomesReport05PaddedTo64() {
        var frame = Data(repeating: 0xAA, count: 62)   // BLE sometimes drops a byte vs USB
        frame[0] = 0x11
        let out = pro.transformRawReport(reportID: nil, data: frame)
        #expect(out?.count == 64)
        #expect(out?.first == 0x05)
        #expect(out?[1] == 0x11)
        #expect(out?[62] == 0xAA)
        #expect(out?[63] == 0x00)   // zero pad
    }

    @Test func fullFrameIsNotTruncatedBeyond63() {
        let frame = Data(repeating: 0x5A, count: 70)
        let out = pro.transformRawReport(reportID: nil, data: frame)
        #expect(out?.count == 64)
    }

    @Test func secondaryReportsAreDropped() {
        // Pro's Report 0x09 must never reach SDL: HandleStatePacket doesn't
        // check the report ID and would parse it as garbage state.
        #expect(pro.transformRawReport(reportID: 0x09, data: Data(repeating: 0, count: 63)) == nil)
    }

    // MARK: rumble relay

    @Test func proRumbleReport02IsRelayedWithByte0Cleared() {
        // SDL UpdateRumble (Pro): [0x02, 0x50|seq, 5 LRA bytes, …, byte 0x11.. = copy of 1..6]
        var body = [UInt8](repeating: 0, count: 63)
        body[0] = 0x53; body[1] = 0x87; body[2] = 0x01; body[3] = 0x10; body[4] = 0x12; body[5] = 0x40
        for i in 0..<6 { body[0x10 + i] = body[i] }
        let out = pro.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x02), data: setReport(0x02, body, paddedTo: 64))
        #expect(out?.count == 42)   // same length ProControllerProfile.encodeRumble emits
        #expect(out?.first == 0x00)
        #expect(out?[1] == 0x53)
        #expect(out?[17] == 0x53 && out?[18] == 0x87)
    }

    @Test func gcRumbleReport03IsRelayed() {
        let body: [UInt8] = [0x51, 0x01]
        let out = gc.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x03), data: setReport(0x03, body, paddedTo: 64))
        #expect(out?.count == 42)   // same length GameCubeProfile.encodeRumble emits
        #expect(out?.prefix(3) == Data([0x00, 0x51, 0x01]))
    }

    @Test func joyConRumbleReport01IsRelayedOnBothSides() {
        let body: [UInt8] = [0x52, 0x87, 0x01, 0x10, 0x12, 0x40]
        for side in [jcL, jcR] {
            let out = side.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x01), data: setReport(0x01, body, paddedTo: 64))
            #expect(out?.count == 42)   // same length JoyConSharedRumble.encode emits
            #expect(out?.prefix(7) == Data([0x00, 0x52, 0x87, 0x01, 0x10, 0x12, 0x40]))
        }
    }

    @Test func wrongRumbleIDForTheProductIsIgnored() {
        // A GC never gets Pro's 0x02, and vice versa — the descriptor doesn't
        // declare it, but the guard is what keeps a stray frame off the LRA char.
        #expect(gc.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x02), data: setReport(0x02, [0x50], paddedTo: 64)) == nil)
        #expect(pro.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x03), data: setReport(0x03, [0x50], paddedTo: 64)) == nil)
        #expect(pro.rawVibrationPayload(type: .feature, id: HIDReportID(rawValue: 0x02), data: setReport(0x02, [0x50], paddedTo: 64)) == nil)
    }

    @Test func rumbleReportShorterThan42IsIgnored() {
        #expect(pro.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x02), data: Data([0x02, 0x50])) == nil)
    }

    // MARK: command tunnel

    @Test func featureMaskFrameIsTrimmedAndRetargetedToBluetooth() {
        // SDL init_sequence "Set feature output bit mask" — sent over bulk as 12 bytes.
        let usb: [UInt8] = [0x0C, 0x91, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00]
        let out = pro.relayCommand(type: .output, id: HIDReportID(rawValue: 0x80), data: setReport(0x80, usb, paddedTo: 65))
        #expect(out == Data([0x0C, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00]))
    }

    @Test func zeroLengthFrameIsEightBytes() {
        let usb: [UInt8] = [0x07, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        let out = gc.relayCommand(type: .output, id: HIDReportID(rawValue: 0x80), data: setReport(0x80, usb, paddedTo: 65))
        #expect(out == Data([0x07, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00]))
    }

    @Test func flashReadFramePreservesAddressBytes() {
        // SDL ReadFlashBlock(0x13140): subcmd 0x01 over USB (WaveBird uses 0x04 — both are relayed verbatim).
        let usb: [UInt8] = [0x02, 0x91, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00,
                            0x00, 0x00, 0x00, 0x00, 0x40, 0x31, 0x01, 0x00]
        let out = gc.relayCommand(type: .output, id: HIDReportID(rawValue: 0x80), data: setReport(0x80, usb, paddedTo: 65))
        #expect(out?.count == 16)
        #expect(out?[2] == 0x01)
        #expect(out?.suffix(4) == Data([0x40, 0x31, 0x01, 0x00]))
    }

    @Test func pairingCommandIsDropped() {
        let usb: [UInt8] = [0x15, 0x91, 0x00, 0x01, 0x00, 0x0E, 0x00, 0x00,
                            0x00, 0x02, 0x81, 0xEB, 0x3A, 0xEB, 0xF1, 0x48, 0x80, 0xEB, 0x3A, 0xEB, 0xF1, 0x48]
        #expect(pro.relayCommand(type: .output, id: HIDReportID(rawValue: 0x80), data: setReport(0x80, usb, paddedTo: 65)) == nil)
    }

    @Test func nonTunnelReportsAreNotCommands() {
        #expect(pro.relayCommand(type: .output, id: HIDReportID(rawValue: 0x02), data: setReport(0x02, [0x50], paddedTo: 64)) == nil)
        #expect(pro.relayCommand(type: .feature, id: HIDReportID(rawValue: 0x80), data: setReport(0x80, [0x07, 0x91, 0x00, 0x01, 0, 0, 0, 0], paddedTo: 65)) == nil)
        #expect(pro.relayCommand(type: .output, id: nil, data: setReport(0x80, [0x07, 0x91, 0x00, 0x01, 0, 0, 0, 0], paddedTo: 65)) == nil)
    }

    @Test func truncatedTunnelReportIsIgnored() {
        // Declared len 0x14 but only 10 payload bytes present.
        let short = Data([0x80, 0x0A, 0x91, 0x00, 0x08, 0x00, 0x14, 0x00, 0x00, 0x01, 0xFF])
        #expect(pro.relayCommand(type: .output, id: HIDReportID(rawValue: 0x80), data: short) == nil)
    }

    @Test func responseReportIs81BytesWithID81() {
        let resp = Data([0x0C, 0x01, 0x01, 0x02, 0x10, 0x78, 0x00, 0x00, 0x01])
        let out = NS2RelayOutput.tunnelResponseReport(resp)
        #expect(out.count == 81)
        #expect(out.first == 0x81)
        #expect(out[1..<10] == resp)
        #expect(out[10] == 0)
        // An 80-byte flash-read response fits exactly; anything longer is cut, never overflowed.
        #expect(NS2RelayOutput.tunnelResponseReport(Data(repeating: 1, count: 90)).count == 81)
    }

    @Test func rumbleIDTable() {
        #expect(NS2RelayOutput.rumbleReportID(forProductID: 0x2069) == 0x02)
        #expect(NS2RelayOutput.rumbleReportID(forProductID: 0x2073) == 0x03)
        #expect(NS2RelayOutput.rumbleReportID(forProductID: 0x2067) == 0x01)
        #expect(NS2RelayOutput.rumbleReportID(forProductID: 0x2066) == 0x01)
        #expect(NS2RelayOutput.rumbleReportID(forProductID: 0x2009) == nil)
    }
}

@MainActor
struct NS2RelayCatalogTests {

    @Test func relayIsInTheDebugCatalogAndNotAllowListed() {
        let catalog = HIDOutputCatalog.default
        #if DEBUG
        let entry = catalog.entry(id: "ns2Relay")
        #expect(entry?.displayName == "NS2 Relay (SDL)")
        #expect(entry?.makeProfile(GameCubeProfile()) is NS2RelayOutput)
        #else
        #expect(catalog.entry(id: "ns2Relay") == nil)
        #endif
        #expect(!HIDOutputCatalog.allowListIDs.contains("ns2Relay"))
        #expect(catalog.entry(id: "ns2Passthrough") == nil)
        #expect(catalog.entry(id: "switch2ProSDL") == nil)
    }

    @Test func removedModeIDsResolveToTheDefaultShippingMode() {
        // Persisted preferences naming the deleted modes must degrade, not crash.
        let catalog = HIDOutputCatalog.default
        #expect(catalog.resolved(id: "ns2Passthrough").id == catalog.firstAllowListedID)
        #expect(catalog.resolved(id: "switch2ProSDL").id == catalog.firstAllowListedID)
    }

    @Test func relayHasNoMappingControls() {
        // Relay bypasses buildReport; mapping is meaningless there.
        #expect(MappingControls.controls(forModeID: "ns2Relay").isEmpty)
    }

    @Test func pairPickerHidesRelayProfiles() {
        // The merged Joy-Con pair never relays. The filter is by base mode ID.
        let store = MappingProfileStore(catalog: .default, defaults: UserDefaults(suiteName: "NS2RelayCatalogTests")!)
        let visible = HIDOutputCatalog.pairSelectableProfiles(from: store.builtInProfiles + store.customProfiles)
        #expect(!visible.contains { $0.baseModeID == "ns2Relay" })
        #expect(visible.contains { $0.baseModeID == "switchPro" })
    }
}
