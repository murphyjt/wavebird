import Foundation
import Testing
@testable import WaveBird

// GIP codec tests. Every expected wire vector below is a byte string taken
// from the protocol's documented wire format and (where noted) cross-checked
// against the linux reference driver's observable behaviour, so the codec's
// output is pinned to interoperability facts rather than to its own
// implementation.
struct GIPCodecTests {

    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }

    // MARK: outbound packets

    @Test func identifyRequestVector() {
        // identify request = 04 20 01 00
        let packet = GIPOutbound.identify(clientID: 0, sequence: 1)
        #expect(hex(packet) == "04200100")
    }

    @Test func powerOnVector() {
        // vectors["power_on"] = 0520020100
        let packet = GIPOutbound.powerOn(clientID: 0, sequence: 2)
        #expect(hex(packet) == "0520020100")
    }

    @Test func ledVector() {
        // vectors["led"] = 0a200403000164
        let packet = GIPOutbound.led(clientID: 0, sequence: 4)
        #expect(hex(packet) == "0A200403000164")
    }

    @Test func rumbleVectorCarriesNoInternalBit() {
        // vectors["rumble"] = 09000309000300006450000000
        // The captured reference frame carries motor mask 0x03 and duration
        // 0x00 (host-driven cadence, immediate stop). We emit xone-style
        // frames instead — motor mask 0x0F and duration 0xFF (run until the
        // stop frame, the linux reference driver's observed behaviour), which
        // pads accept either way — so only the header side of the vector is
        // pinned here. The property under test is the header: cmd 0x09 with
        // options 0x00 — rumble has NO INTERNAL bit (hdr.options = client id
        // only).
        let payload = GIPRumble.payload(leftAmp: 65535, rightAmp: 52429)
        let packet = GIPOutbound.rumble(clientID: 0, sequence: 3, payload: payload)
        #expect(hex(Data(packet.prefix(4))) == "09000309")
        #expect(packet[1] == 0x00)
    }

    @Test func acknowledgeVector() {
        // vectors["ack_chunk0"] = 012005090004003a0000006b04
        let ack = GIPOutbound.acknowledge(
            clientID: 0, sequence: 5,
            ackedCommand: .identify,
            ackedOptions: GIPOptions(rawValue: 0x20 | 0x80 | 0x40),
            ackedLength: 58, transferTotal: 1189)
        #expect(hex(ack) == "012005090004003A0000006B04")
    }

    @Test func oddLengthHeaderPadsWithContinuationByte() {
        // vectors["odd_padded_header"] = 090007c88100 (packet length 200)
        let header = GIPHeader(command: .rumble, options: GIPOptions(rawValue: 0), sequence: 7, packetLength: 200)
        let encoded = GIPHeaderCodec.encode(header)
        #expect(hex(encoded) == "090007C88100")
        let decoded = GIPHeaderCodec.decode(encoded)
        #expect(decoded != nil)
        #expect(decoded!.header.packetLength == 200)
        #expect(decoded!.headerLength == 6)
    }

    @Test func chunkHeadersCarryTotalInFirstChunkOffset() {
        // vectors["chunk_first_header"] = 04f0063aa509… (1189-byte identify,
        // first chunk: CHUNK_START|CHUNK|ACK, offset = TOTAL).
        var first = GIPHeader(command: .identify,
                              options: GIPOptions(rawValue: 0x20 | 0x10 | 0x40 | 0x80),
                              sequence: 6, packetLength: 58, chunkOffset: 1189)
        let firstBytes = GIPHeaderCodec.encode(first)
        #expect(hex(Data(firstBytes.prefix(6))) == "04F0063AA509")
        // vectors["chunk_done_header"] = 04a00600a509 (completion: len 0,
        // offset = TOTAL, no ACK/START).
        first.options = GIPOptions(rawValue: 0x20 | 0x80)
        first.packetLength = 0
        first.chunkOffset = 1189
        #expect(hex(GIPHeaderCodec.encode(first)) == "04A00600A509")
    }

    // MARK: stream parsing

    @Test func parsesBackToBackInputFrames() {
        // Two 13-byte input packets (4-byte header + 9-byte rumble-shaped
        // payload) share one 26-byte buffer.
        let a = GIPOutbound.rumble(clientID: 0, sequence: 1, payload: Data(repeating: 0x11, count: 9))
        let b = GIPOutbound.rumble(clientID: 0, sequence: 2, payload: Data(repeating: 0x22, count: 9))
        var parser = GIPStreamParser()
        let messages = parser.feed(a + b)
        #expect(messages.count == 2)
        #expect(messages[0].header.sequence == 1)
        #expect(messages[1].header.sequence == 2)
        #expect(messages[1].payload.first == 0x22)
    }

    @Test func reassemblesPacketSplitAcrossReads() {
        let frame = GIPOutbound.rumble(clientID: 0, sequence: 9, payload: Data(repeating: 0x55, count: 9))
        var parser = GIPStreamParser()
        #expect(parser.feed(frame.prefix(2)).isEmpty)      // header split
        #expect(parser.feed(frame.dropFirst(2).prefix(3)).isEmpty)
        let done = parser.feed(frame.dropFirst(5))
        #expect(done.count == 1)
        #expect(done[0].header.packetLength == 9)
    }

    @Test func reassemblesChunkedIdentifyTransfer() {
        // Build a large "identify" payload and chunk it exactly like the
        // controller does (first chunk offset = TOTAL, mid
        // chunks = running offset, last chunk ACK, empty completion chunk).
        let payload = Data(repeating: 0xAB, count: 133)
        var frames: [Data] = []
        func hdr(_ options: UInt8, _ plen: Int, _ coff: Int) -> Data {
            GIPHeaderCodec.encode(GIPHeader(command: .identify,
                                            options: GIPOptions(rawValue: options),
                                            sequence: 6, packetLength: plen, chunkOffset: coff))
        }
        let total = payload.count
        var n = 0
        var started = false
        while n < total {
            let this = min(58, total - n)
            var opts: UInt8 = 0x20 | 0x80   // INTERNAL | CHUNK
            if !started { opts |= 0x40 | 0x10; started = true }   // CHUNK_START|ACK, offset = TOTAL
            if n + this == total { opts |= 0x10 }                 // last chunk ACK
            frames.append(hdr(opts, this, started && n != 0 ? n : total) + payload[n..<(n + this)])
            n += this
        }
        frames.append(hdr(0x20 | 0x80, 0, total))   // empty completion chunk

        var parser = GIPStreamParser()
        var got: Data?
        for frame in frames {
            for message in parser.feed(frame) { got = message.payload }
        }
        #expect(got == payload)
    }

    @Test func chunkedDeliveryWithACKEvents() {
        // The parser must surface every chunked header (with its wire
        // chunkOffset) so the transport can ACK with length = offset+length.
        var parser = GIPStreamParser()
        let total = 1189
        let first = GIPHeaderCodec.encode(GIPHeader(command: .identify,
                                                    options: GIPOptions(rawValue: 0x20 | 0x10 | 0x40 | 0x80),
                                                    sequence: 6, packetLength: 58, chunkOffset: total))
        let messages = parser.feed(first + Data(repeating: 0, count: 58))
        #expect(messages.isEmpty)   // chunk reassembly in progress
        // Completing the transfer returns exactly one message whose header
        // still shows the chunk flags (used by the ACK path).
        let last = GIPHeaderCodec.encode(GIPHeader(command: .identify,
                                                   options: GIPOptions(rawValue: 0x20 | 0x80),
                                                   sequence: 6, packetLength: 0, chunkOffset: total))
        let done = parser.feed(last)
        #expect(done.count == 1)
        #expect(done[0].header.options.containsChunk)
    }

    // MARK: identify info block

    @Test func parsesIdentifyInfoBlock() {
        // Fixture layout mirrors the identify info block format:
        // [unknown 16][8 × u16le offsets][elements]; offsets measured from
        // payload+16 (offsets are measured past the 16-byte header).
        func u16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
        var info = Data(repeating: 0, count: 16)                    // pkt->unknown

        var classes = Data([2])                                     // count
        for s in ["Windows.Xbox.Input.Gamepad", "Windows.Xbox.System"] {
            let bytes = Data(s.utf8)
            classes += u16(bytes.count) + bytes
        }
        let fwSeg = Data([2]) + u16(3) + u16(1) + u16(5) + u16(0)   // 2 × (major, minor)
        let ifaceSeg = Data([1]) + Data(repeating: 0x42, count: 16) // 1 × GUID

        var elements = Data()
        let offCMDs = 16 + elements.count
        let offFW = 16 + (elements.count + 0)
        var fwBase = 0
        fwBase = elements.count
        elements += fwSeg
        let offIfaces = 16 + elements.count
        elements += ifaceSeg
        let offClasses = 16 + elements.count
        elements += classes

        info += u16(0)      // client_commands (absent)
        info += u16(offFW)  // firmware_versions
        info += u16(0)      // audio_formats
        info += u16(0)      // capabilities_out
        info += u16(0)      // capabilities_in
        info += u16(offClasses)
        info += u16(offIfaces)
        info += u16(0)      // hid_descriptor
        info += elements
        _ = offCMDs

        let parsed = GIPIdentifyInfo.parse(info)
        #expect(parsed != nil)
        #expect(parsed!.classes == ["Windows.Xbox.Input.Gamepad", "Windows.Xbox.System"])
        #expect(parsed!.isGamepad)
        #expect(parsed!.firmwareVersions.count == 2)
        #expect(parsed!.firmwareVersions[0] == (3, 1))
        #expect(parsed!.interfaces.count == 1)
    }

    // MARK: input parsing

    @Test func parsesGamepadInputReport() {
        // 14-byte GIP input: buttons, triggers, 4 sticks (all s16 LE).
        var frame = Data(repeating: 0, count: 14)
        frame[0] = 0x10; frame[1] = 0x01              // A (1<<4) + Guide synthetic bit0
        frame[2] = 0xFF; frame[3] = 0x03              // trigger L = 1023
        frame[4] = 0x00; frame[5] = 0x02              // trigger R = 512
        // left stick (16384, 16384) — up-right
        frame[6] = 0x00; frame[7] = 0x40
        frame[8] = 0x00; frame[9] = 0x40
        let input = GIPGamepadInput.parse(frame)
        #expect(input != nil)
        #expect(input!.buttons == 0x0110)
        #expect(input!.triggerLeft == 1023)
        #expect(input!.triggerRight == 512)
        #expect(input!.stickLeftX == 16384)
        #expect(input!.stickLeftY == 16384)
    }

    // MARK: profile integration

    @Test func profileParsesInputPacketIntoState() {
        let profile = XboxOneProfile()
        var frame = Data(repeating: 0, count: 14)
        // low byte 0x9C: Menu (1<<2), View (1<<3), A-south (1<<4), Y-north (1<<7) —
        // B-east (1<<5) / X-west (1<<6) clear.
        // high byte 0xFF: dpad U/D/L/R (1<<8…11), LB/RB (1<<12/13),
        // L3/R3 (1<<14/15) all set.
        // Canonical members are position-based (.a=east .b=south .x=north
        // .y=west) — so the south press lands in .b and the north in .x.
        frame[0] = 0x9C; frame[1] = 0xFF
        frame[2] = 0xFF; frame[3] = 0x03   // LT = 1023 → 255
        frame[4] = 0x00; frame[5] = 0x01   // RT = 256 → 64
        frame[6] = 0x00; frame[7] = 0x40   // LX 16384 → 1023 (of 2047)
        frame[8] = 0x00; frame[9] = 0xC0   // LY −16384 → −1023 (up is positive… this is down)
        let state = profile.parseUSBReport(frame, reportID: 0, calibration: ControllerCalibration())
        #expect(state != nil)
        let s = state!
        #expect(s.buttons.contains(.b))
        #expect(s.buttons.contains(.x))
        #expect(s.buttons.contains(.start))
        #expect(s.buttons.contains(.minus))
        #expect(!s.buttons.contains(.a))
        #expect(s.buttons.contains(.dpadUp))
        #expect(s.buttons.contains(.stickL))
        #expect(s.buttons.contains(.stickR))
        #expect(s.triggerL == 255)
        #expect(s.triggerR == 64)
        #expect(s.leftStick.x == 1023)
        #expect(s.leftStick.y == -1023)
        #expect(s.shoulders.leftBumper)
        #expect(s.shoulders.rightBumper)
        #expect(s.shoulders.leftTriggerAnalog == 255)
    }

    @Test func profileMapsGuideSyntheticBit() {
        // Bit 0 of the buttons word = synthetic Guide channel (transport
        // latch). Also: a bare 0x07 "edge" report maps to .home.
        let profile = XboxOneProfile()
        var frame = Data(repeating: 0, count: 14)
        frame[0] = 0x01
        let state = profile.parseUSBReport(frame, reportID: 0, calibration: ControllerCalibration())
        #expect(state?.buttons.contains(.home) == true)

        let edge = profile.parseUSBReport(Data([0x01]), reportID: 0x07, calibration: ControllerCalibration())
        #expect(edge?.buttons.contains(.home) == true)
        let edgeUp = profile.parseUSBReport(Data([0x00]), reportID: 0x07, calibration: ControllerCalibration())
        #expect(edgeUp?.buttons.contains(.home) == false)
    }

    @Test func rumblePayloadsUseExpectedFrameShape() {
        let active = GIPRumble.payload(leftAmp: 65535, rightAmp: 52429)
        #expect(active.count == 9)
        #expect(active[1] == 0x0F)          // motors R|L|RT|LT
        #expect(active[4] == 100)           // L amp (65535 → 100)
        #expect(active[5] == 80)            // R amp (52429 → 80)
        #expect(active[6] == 0xFF)          // duration 0xFF = run until the stop frame
        #expect(active[8] == 0xEB)          // repeat 0xEB (xone keeps it on live frames too)
        let stop = GIPRumble.payload(leftAmp: 0, rightAmp: 0)
        #expect(stop[1] == 0x0F)
        #expect(stop[6] == 0xFF)            // duration 0xFF (stop frame)
        #expect(stop[8] == 0xEB)            // repeat 0xEB (stop frame)
    }

    // MARK: share button / DLI

    @Test func shareByteOffsetRules() {
        // Share byte sits at len−18 (non-DLI) or len−26 (DLI, +8 counter).
        var p = Data(repeating: 0, count: 18)
        p[0] = 0x01
        #expect(GIPGamepadInput.shareByte(payload: p, supportsDLI: false) == 0x01)
        // 18 < 26 → packet too short for a DLI pad's share byte
        #expect(GIPGamepadInput.shareByte(payload: p, supportsDLI: true) == nil)
        var q = Data(repeating: 0, count: 26)
        q[0] = 0x01
        #expect(GIPGamepadInput.shareByte(payload: q, supportsDLI: true) == 0x01)
        #expect(GIPGamepadInput.shareByte(payload: Data(count: 5), supportsDLI: false) == nil)
    }

    @Test func identifyInfoReportsShareAndDLI() {
        let share = Data([0xFE, 0xD2, 0xDD, 0xEC, 0x87, 0xD3, 0x94, 0x42, 0xBD, 0x96, 0x1A, 0x71, 0x2E, 0x3D, 0xC7, 0x7D])
        let dli   = Data([0x6B, 0xE5, 0xF2, 0x87, 0xBB, 0xC3, 0xB1, 0x49, 0x82, 0x65, 0xFF, 0xFF, 0xF3, 0x77, 0x99, 0xEE])
        var withShare = GIPIdentifyInfo(); withShare.interfaces = [share]
        #expect(withShare.supportsShare)
        #expect(!withShare.supportsDLI)
        var withDLI = GIPIdentifyInfo(); withDLI.interfaces = [dli]
        #expect(withDLI.supportsDLI)
        #expect(!withDLI.supportsShare)
        // The 1537 advertises neither.
        let bare = GIPIdentifyInfo()
        #expect(!bare.supportsShare && !bare.supportsDLI)
    }

    @Test func profileMapsShareSyntheticBit() {
        let profile = XboxOneProfile()
        var frame = Data(repeating: 0, count: 14)
        frame[0] = 0x02   // reserved bit 1 = synthetic Share channel
        let state = profile.parseUSBReport(frame, reportID: 0, calibration: ControllerCalibration())
        #expect(state?.buttons.contains(.capture) == true)
    }

    // MARK: trigger rumble

    @Test func triggerRumblePayloadPopulatesLTAndRT() {
        let p = GIPRumble.payload(leftAmp: 0, rightAmp: 0, leftTriggerAmp: 65535, rightTriggerAmp: 39321)
        #expect(p.count == 9)
        #expect(p[1] == 0x0F)          // motors R|L|RT|LT
        #expect(p[2] == 100)           // LT = 65535 → 100
        #expect(p[3] == 60)            // RT = 39321 → 60
        #expect(p[4] == 0 && p[5] == 0) // main motors silent
        // Active frames always carry duration 0xFF (run until the stop
        // frame); stop-ness is decided by amplitude at the RumbleCommand
        // level, not by the duration byte.
        #expect(p[6] == 0xFF)
        #expect(p[8] == 0xEB)
    }

    @Test func triggerOnlyRumbleIsNotStop() {
        let triggers = RumbleCommand(leftAmp: 0, rightAmp: 0, leftTriggerAmp: 100, rightTriggerAmp: 0)
        #expect(!triggers.isStop)
        #expect(RumbleCommand().isStop)
    }

    // MARK: discovery matching

    @Test func usbMatcherMatchesAnyGIPPadByDefault() {
        let any = USBMatcher(initWrites: [])
        #expect(any.matches(vendorID: 0x3537, productID: 0x1022))   // GameSir G7 Pro (GIP)
        #expect(any.matches(vendorID: 0x045E, productID: 0x02D1))   // 1537
        #expect(any.matches(productID: 0x0000))                     // unknown PID still matches
        let narrowed = USBMatcher(vendorIDs: [0x045E], productIDs: [0x02D1])
        #expect(narrowed.matches(vendorID: 0x045E, productID: 0x02D1))
        #expect(!narrowed.matches(vendorID: 0x3537, productID: 0x1022))
    }
}
