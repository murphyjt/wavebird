// Switch 1 Pro Controller spoof emulator.
//
// macOS's AppleGameControllerPersonality driver matches Switch Pro by
// VID/PID (0x057E/0x2009). When it sees the matching HID descriptor it
// drives Nintendo's proprietary Bluetooth handshake — Output Report 0x01
// carrying a subcommand, expecting an Input Report 0x21 reply — and refuses
// to bind GameController.framework until that handshake completes. This
// actor emulates the controller side of that protocol: it interprets the
// subcommands Apple's driver sends, dispatches plausible 0x21 replies, and
// switches the input report format from simple mode (0x3F) to full mode
// (0x30) once the driver requests it.
//
// Protocol details cross-referenced against:
//   - libsdl-org/SDL `src/joystick/hidapi/SDL_hidapi_switch.c` (zlib license).
//     Specifically the SwitchSubcommandInputPacket_t layout, subcommand IDs,
//     and SPI flash addresses. See README Credits.
//   - dekuNukem/Nintendo_Switch_Reverse_Engineering — bluetooth HID
//     subcommands and report 0x30 button/stick layout.
//
// We only emulate the subset of subcommands needed for Apple's driver to
// finish init — RequestDeviceInfo, SetInputReportMode, SPIFlashRead (for
// stick/IMU calibration), EnableIMU, EnableVibration, SetPlayerLights,
// SetIMUSensitivity, and a few NOPs. Anything else gets a plain ACK.

import CoreHID
import Foundation

actor SwitchProSpoof {
    enum InputMode: UInt8 {
        case simple = 0x3F
        case full   = 0x30
    }

    private(set) var inputMode: InputMode = .simple
    private var replyCounter: UInt8 = 0
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
    }

    // Process a Set Report request. Output Report 0x01 carries Bluetooth
    // rumble + subcommands and expects Input Report 0x21 replies. Output
    // Report 0x80 is Nintendo's USB/proprietary command channel used by SDL
    // and similar HIDAPI stacks; it expects Input Report 0x81 replies.
    // `device` is passed through so we can dispatch the matching reply without
    // holding a back-reference.
    //
    // The reply dispatch fires on a detached Task on purpose: CoreHID's
    // delegate caller awaits this method, and `dispatchInputReport` re-enters
    // CoreHID. Awaiting inline produced a reentrancy hang that wedged the
    // whole HID subsystem when Apple's Switch Pro driver bound the device.
    //
    // CoreHID delivers the FULL report including the leading ID byte in `data`
    // (it also parses the ID into `id` for convenience). So Output Report 0x01
    // payload layout in `data`:
    //   [0]:    0x01 (= report ID, = Nintendo's "packet type" — same byte)
    //   [1]:    packet counter (host increments per command)
    //   [2..5]: rumble L (4 bytes)
    //   [6..9]: rumble R (4 bytes)
    //   [10]:   subcommand ID
    //   [11+]:  subcommand args
    func handleSetReport(device: HIDVirtualDevice, type: HIDReportType, id: HIDReportID?, data: Data) async {
        guard type == .output, let id else { return }
        let rid = id.rawValue
        let base = data.startIndex
        if rid == 0x80, data.count >= 2 {
            let commandID = data[base + 1]
            log("OUT 0x80 proprietary=0x\(String(format: "%02X", commandID))")
            let reply = buildProprietaryReply(commandID: commandID)
            Task { try? await device.dispatchInputReport(data: reply, timestamp: .now) }
            return
        }

        guard rid == 0x01, data.count >= 11 else {
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            log("OUT id=0x\(String(format: "%02X", rid)) len=\(data.count) [\(hex)] (ignored)")
            return
        }
        let counter = data[base + 1]
        let subcmdID = data[base + 10]
        let args = data.subdata(in: (base + 11)..<data.endIndex)
        let argHex = args.map { String(format: "%02X", $0) }.joined(separator: " ")
        log("OUT 0x01 counter=\(counter) subcmd=0x\(String(format: "%02X", subcmdID)) args=[\(argHex)]")
        let reply = buildSubcommandReply(subcmdID: subcmdID, args: args)
        Task { try? await device.dispatchInputReport(data: reply, timestamp: .now) }
    }

    // Build the live input report. Layout depends on which mode the host has
    // put us into via subcommand 0x03.
    func buildReport(_ state: ControllerState, source: any ControllerProfile) -> Data {
        switch inputMode {
        case .simple: return buildSimpleReport(state, source: source)
        case .full:   return buildFullReport(state, source: source)
        }
    }

    // MARK: - Subcommand reply construction

    private func buildSubcommandReply(subcmdID: UInt8, args: Data) -> Data {
        var ack: UInt8 = 0x80
        var payload = [UInt8](repeating: 0, count: 34)

        switch subcmdID {
        case 0x02:  // Request device info
            ack = 0x82
            payload[0] = 0x04          // firmware major
            payload[1] = 0x21          // firmware minor (v4.33)
            payload[2] = 0x03          // controller type: Pro Controller
            payload[3] = 0x02          // unknown / filler
            // MAC (big-endian) — first three bytes match Nintendo's OUI
            payload[4] = 0x98
            payload[5] = 0xB6
            payload[6] = 0xE9
            payload[7] = 0x12
            payload[8] = 0x34
            payload[9] = 0x56
            payload[10] = 0x01         // unknown / filler
            payload[11] = 0x02         // color location: use default colors

        case 0x03:  // Set input report mode
            if let mode = args.first.flatMap({ InputMode(rawValue: $0) }) {
                inputMode = mode
                log("subcmd 0x03: input mode → 0x\(String(format: "%02X", mode.rawValue))")
            }

        case 0x10:  // SPI flash read
            // args[0..3] = address (LE), args[4] = length.
            guard args.count >= 5 else { break }
            let addr = UInt32(args[args.startIndex])
                | (UInt32(args[args.startIndex + 1]) << 8)
                | (UInt32(args[args.startIndex + 2]) << 16)
                | (UInt32(args[args.startIndex + 3]) << 24)
            let len = Int(args[args.startIndex + 4])
            ack = 0x90
            // Echo the read header (address + length) — driver checks this matches.
            payload[0] = args[args.startIndex]
            payload[1] = args[args.startIndex + 1]
            payload[2] = args[args.startIndex + 2]
            payload[3] = args[args.startIndex + 3]
            payload[4] = args[args.startIndex + 4]
            let flash = spiFlash(address: addr, length: len)
            let copyLen = min(len, flash.count, payload.count - 5)
            for i in 0..<copyLen {
                payload[5 + i] = flash[flash.startIndex + i]
            }
            log("subcmd 0x10: SPI read addr=0x\(String(format: "%04X", addr)) len=\(len)")

        case 0x30:  // Set player lights — ack only
            log("subcmd 0x30: set player lights")
        case 0x38:  // Set HOME light — ack only
            log("subcmd 0x38: set home light")
        case 0x40:  // Enable IMU — ack only
            log("subcmd 0x40: enable IMU")
        case 0x41:  // Set IMU sensitivity — ack only
            log("subcmd 0x41: set IMU sensitivity")
        case 0x48:  // Enable vibration — ack only
            log("subcmd 0x48: enable vibration")
        case 0x21, 0x22:  // NFC/IR MCU config / state — ack only
            log("subcmd 0x\(String(format: "%02X", subcmdID)): NFC/IR")
        case 0x06:  // Set HCI state (sleep/reset) — ack only
            log("subcmd 0x06: HCI state")
        case 0x08:  // Set shipment low-power state — ack only
            log("subcmd 0x08: shipment state")
        default:
            log("subcmd 0x\(String(format: "%02X", subcmdID)): plain ack")
        }

        return buildReplyReport(ack: ack, subcmdID: subcmdID, payload: payload)
    }

    // Input Report 0x21. The Switch Bluetooth payload is 49 bytes on the wire
    // (1 ID + 48 payload), but USB/HIDAPI stacks expect max-size 64-byte
    // reports even for this same subcommand-reply layout.
    //   0:      Report ID (0x21)
    //   1:      counter
    //   2:      battery + connection (0x90 = full + USB/charged)
    //   3..5:   buttons (zero — no input on handshake replies)
    //   6..8:   left stick (neutral packed)
    //   9..11:  right stick (neutral packed)
    //   12:     vibration ack
    //   13:     subcommand ack byte
    //   14:     subcommand ID (echoed)
    //   15..48: subcommand reply payload (34 bytes)
    private func buildReplyReport(ack: UInt8, subcmdID: UInt8, payload: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x21
        bytes[1] = nextCounter()
        bytes[2] = 0x90
        // sticks neutral: 12-bit 0x800 packed → 0x00 0x08 0x80
        bytes[6]  = 0x00; bytes[7]  = 0x08; bytes[8]  = 0x80
        bytes[9]  = 0x00; bytes[10] = 0x08; bytes[11] = 0x80
        bytes[13] = ack
        bytes[14] = subcmdID
        for i in 0..<min(payload.count, 34) {
            bytes[15 + i] = payload[i]
        }
        return Data(bytes)
    }

    // Input Report 0x81 is the reply to Output Report 0x80. SDL only checks
    // bytes [0] and [1] for most commands; Status additionally carries the
    // controller type and reversed MAC address.
    private func buildProprietaryReply(commandID: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x81
        bytes[1] = commandID
        switch commandID {
        case 0x01:  // Status
            bytes[2] = 0x00
            bytes[3] = 0x03  // Pro Controller
            bytes[4] = 0x56
            bytes[5] = 0x34
            bytes[6] = 0x12
            bytes[7] = 0xE9
            bytes[8] = 0xB6
            bytes[9] = 0x98
            log("proprietary 0x01: status")
        case 0x02:
            log("proprietary 0x02: handshake")
        case 0x03:
            log("proprietary 0x03: high speed")
        case 0x04:
            log("proprietary 0x04: force USB")
        case 0x05:
            log("proprietary 0x05: clear USB")
        case 0x06:
            log("proprietary 0x06: reset MCU")
        default:
            log("proprietary 0x\(String(format: "%02X", commandID)): ack")
        }
        return Data(bytes)
    }

    private func nextCounter() -> UInt8 {
        let v = replyCounter
        replyCounter = (replyCounter &+ 3) & 0xFF  // SDL & Nintendo firmware step by 3
        return v
    }

    // MARK: - SPI flash spoofing
    //
    // Apple's driver reads various flash regions during init. We return
    // plausible factory defaults for the ones it normally checks and 0xFF
    // (uninitialized) for everything else — including the user-calibration
    // regions, which is what an out-of-box controller would return.
    //
    // Address map (from SDL_hidapi_switch.c constants and dekuNukem docs):
    //   0x6020..0x6037 (24B): factory sensor (IMU) calibration
    //   0x603D..0x604E (18B): factory stick calibration (L+R, 9B each)
    //   0x6050..0x6055 (6B):  body + button colors (RGB pairs)
    //   0x6080..0x6086 (7B):  factory stick parameters magic
    //   0x6098..0x60A9 (18B): factory IMU offset
    //   0x8010..0x8025 (22B): user stick calibration (0xFF = unset)
    //   0x8026..0x8039 (20B): user IMU calibration (0xFF = unset)
    private func spiFlash(address: UInt32, length: Int) -> Data {
        var out = Data(repeating: 0xFF, count: length)

        switch address {
        case 0x6020:
            // Factory IMU calibration — accel offsets + gains, gyro offsets + gains.
            let cal: [UInt8] = [
                0xBA, 0x15, 0x62, 0x11, 0x09, 0x10,   // accel offsets
                0x00, 0x40, 0x00, 0x40, 0x00, 0x40,   // accel sensitivity
                0xC7, 0x79, 0x9C, 0xFF, 0xC7, 0x7F,   // gyro offsets
                0x3B, 0x34, 0x3B, 0x34, 0x3B, 0x34,   // gyro sensitivity
            ]
            for i in 0..<min(length, cal.count) { out[out.startIndex + i] = cal[i] }

        case 0x603D:
            // Factory stick calibration — symmetric, centered at 0x800,
            // 0x800 above and 0x800 below. Packed (12,12)→3 bytes → 0x00 0x08 0x80.
            let stick: [UInt8] = [
                0x00, 0x08, 0x80, 0x00, 0x08, 0x80, 0x00, 0x08, 0x80,  // L: max, center, min
                0x00, 0x08, 0x80, 0x00, 0x08, 0x80, 0x00, 0x08, 0x80,  // R: center, min, max
            ]
            for i in 0..<min(length, stick.count) { out[out.startIndex + i] = stick[i] }

        case 0x6050:
            // Body color (3 bytes) + buttons color (3 bytes). Pro black.
            let colors: [UInt8] = [0x32, 0x32, 0x32, 0xFF, 0xFF, 0xFF]
            for i in 0..<min(length, colors.count) { out[out.startIndex + i] = colors[i] }

        case 0x6080:
            // Factory stick parameters 1 — magic bytes the driver pattern-matches.
            let params: [UInt8] = [0x50, 0xFD, 0x00, 0x00, 0xC6, 0x0F, 0x0F]
            for i in 0..<min(length, params.count) { out[out.startIndex + i] = params[i] }

        case 0x6086:
            // Factory stick parameters 2 — left stick dead-zone / range.
            let params: [UInt8] = [
                0x0F, 0x30, 0x61, 0xAE, 0x90, 0xD9, 0xD4, 0x14, 0x54,
                0x41, 0x15, 0x54, 0xC7, 0x79, 0x9C, 0x33, 0x36, 0x63,
            ]
            for i in 0..<min(length, params.count) { out[out.startIndex + i] = params[i] }

        case 0x6098:
            // Factory IMU horizontal offsets.
            let imu: [UInt8] = [
                0xE8, 0xFF, 0xF8, 0xFF, 0x40, 0x00,
                0x00, 0x40, 0x00, 0x40, 0x00, 0x40,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ]
            for i in 0..<min(length, imu.count) { out[out.startIndex + i] = imu[i] }

        default:
            break  // already 0xFF (uninitialized) — correct for user-cal regions
        }
        return out
    }

    // MARK: - Live input reports

    // Report 0x3F (simple HID mode, 12 bytes):
    //   0:      0x3F
    //   1..2:   16-button bitmap (LE)
    //   3:      low nibble = hat, high nibble = padding
    //   4..11:  X, Y, Rx, Ry (UInt16 LE, 0..65535, neutral 0x8000, +Y=down)
    nonisolated private func buildSimpleReport(_ state: ControllerState, source: any ControllerProfile) -> Data {
        let s = state.buttons
        let sh = source.standardShoulders(state)
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = 0x3F

        var b: UInt16 = 0
        if s.contains(.b)         { b |= 1 << 0 }
        if s.contains(.a)         { b |= 1 << 1 }
        if s.contains(.y)         { b |= 1 << 2 }
        if s.contains(.x)         { b |= 1 << 3 }
        if sh.leftBumper          { b |= 1 << 4 }
        if sh.rightBumper         { b |= 1 << 5 }
        if sh.leftTriggerDigital  { b |= 1 << 6 }
        if sh.rightTriggerDigital { b |= 1 << 7 }
        if s.contains(.minus)     { b |= 1 << 8 }
        if s.contains(.plus) || s.contains(.start) { b |= 1 << 9 }
        if s.contains(.stickL)    { b |= 1 << 10 }
        if s.contains(.stickR)    { b |= 1 << 11 }
        if s.contains(.home)      { b |= 1 << 12 }
        if s.contains(.capture)   { b |= 1 << 13 }
        bytes[1] = UInt8(b & 0xFF)
        bytes[2] = UInt8(b >> 8)

        bytes[3] = simpleHat(
            up: s.contains(.dpadUp),
            right: s.contains(.dpadRight),
            down: s.contains(.dpadDown),
            left: s.contains(.dpadLeft)
        ) & 0x0F

        let lx = axis16(state.leftStick.x)
        let ly = axis16(-Int(state.leftStick.y))   // HID +Y=down
        let rx = axis16(state.rightStick.x)
        let ry = axis16(-Int(state.rightStick.y))
        bytes[4]  = UInt8(lx & 0xFF); bytes[5]  = UInt8(lx >> 8)
        bytes[6]  = UInt8(ly & 0xFF); bytes[7]  = UInt8(ly >> 8)
        bytes[8]  = UInt8(rx & 0xFF); bytes[9]  = UInt8(rx >> 8)
        bytes[10] = UInt8(ry & 0xFF); bytes[11] = UInt8(ry >> 8)
        return Data(bytes)
    }

    // Report 0x30 (full input mode). The useful Nintendo payload is the first
    // 49 bytes; USB/HIDAPI clients expect the report padded to 64 bytes.
    //   0:      0x30
    //   1:      counter
    //   2:      battery + connection (0x90)
    //   3..5:   buttons (Pro layout, 3 bytes)
    //   6..8:   left stick (packed 12-bit X+Y)
    //   9..11:  right stick (packed 12-bit X+Y)
    //   12:     vibration code
    //   13..48: IMU data (3 samples × 12 bytes — zeroed; IMU not exposed)
    func buildFullReport(_ state: ControllerState, source: any ControllerProfile) -> Data {
        let s = state.buttons
        let sh = source.standardShoulders(state)
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x30
        bytes[1] = nextCounter()
        bytes[2] = 0x90

        // Button byte 0 (right side): Y, X, B, A, SR, SL, R, ZR
        var br: UInt8 = 0
        if s.contains(.y)         { br |= 1 << 0 }
        if s.contains(.x)         { br |= 1 << 1 }
        if s.contains(.b)         { br |= 1 << 2 }
        if s.contains(.a)         { br |= 1 << 3 }
        if sh.rightBumper         { br |= 1 << 6 }   // R
        if sh.rightTriggerDigital { br |= 1 << 7 }   // ZR
        bytes[3] = br

        // Button byte 1 (middle): Minus, Plus, RStick, LStick, Home, Capture
        var bm: UInt8 = 0
        if s.contains(.minus)     { bm |= 1 << 0 }
        if s.contains(.plus) || s.contains(.start) { bm |= 1 << 1 }
        if s.contains(.stickR)    { bm |= 1 << 2 }
        if s.contains(.stickL)    { bm |= 1 << 3 }
        if s.contains(.home)      { bm |= 1 << 4 }
        if s.contains(.capture)   { bm |= 1 << 5 }
        bytes[4] = bm

        // Button byte 2 (left side): Down, Up, Right, Left, SR, SL, L, ZL
        var bl: UInt8 = 0
        if s.contains(.dpadDown)  { bl |= 1 << 0 }
        if s.contains(.dpadUp)    { bl |= 1 << 1 }
        if s.contains(.dpadRight) { bl |= 1 << 2 }
        if s.contains(.dpadLeft)  { bl |= 1 << 3 }
        if sh.leftBumper          { bl |= 1 << 6 }   // L
        if sh.leftTriggerDigital  { bl |= 1 << 7 }   // ZL
        bytes[5] = bl

        let (l0, l1, l2) = packStick12(x: state.leftStick.x, y: -Int(state.leftStick.y))
        let (r0, r1, r2) = packStick12(x: state.rightStick.x, y: -Int(state.rightStick.y))
        bytes[6]  = l0; bytes[7]  = l1; bytes[8]  = l2
        bytes[9]  = r0; bytes[10] = r1; bytes[11] = r2
        return Data(bytes)
    }
    // MARK: - Encoding helpers

    // Pack two 12-bit values into 3 bytes (Nintendo's stick wire format).
    nonisolated private func packStick12(x: Int8, y: Int) -> (UInt8, UInt8, UInt8) {
        let xv = Self.toStick12(Int(x))
        let yv = Self.toStick12(y)
        let b0 = UInt8(xv & 0xFF)
        let b1 = UInt8((xv >> 8) & 0x0F) | UInt8((yv & 0x0F) << 4)
        let b2 = UInt8((yv >> 4) & 0xFF)
        return (b0, b1, b2)
    }

    // -128..127 (signed) → 0..4095 (12-bit unsigned), neutral 2048.
    private static func toStick12(_ v: Int) -> UInt16 {
        let mapped = 2048 + v * 16
        return UInt16(clamping: mapped)
    }

    nonisolated private func axis16(_ v: Int8) -> UInt16 { Self.toAxis16(Int(v)) }
    nonisolated private func axis16(_ v: Int) -> UInt16 { Self.toAxis16(v) }

    private static func toAxis16(_ value: Int) -> UInt16 {
        if value >= 0 { return UInt16(clamping: 0x8000 + value * 258) }
        else          { return UInt16(clamping: 0x8000 + value * 256) }
    }

    nonisolated private func simpleHat(up: Bool, right: Bool, down: Bool, left: Bool) -> UInt8 {
        switch (up, right, down, left) {
        case (true,  false, false, false): return 0
        case (true,  true,  false, false): return 1
        case (false, true,  false, false): return 2
        case (false, true,  true,  false): return 3
        case (false, false, true,  false): return 4
        case (false, false, true,  true ): return 5
        case (false, false, false, true ): return 6
        case (true,  false, false, true ): return 7
        default: return 8
        }
    }
}
