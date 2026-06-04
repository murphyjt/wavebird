import CoreHID
import Foundation

// Microsoft Xbox Wireless Controller, VID 0x045E / PID 0x0B13 (BLE Series X).
//
// The descriptor below is byte-for-byte the report descriptor dumped from a real
// Series X over BLE (IOKit kIOHIDReportDescriptorKey, 2026-05-31): one input
// report (0x01) and one PID rumble output report (0x03). Apple's
// XboxOneHIDServicePlugin binds it as a GCController immediately (no GIP
// handshake). Full architecture + the dumped descriptor: see Xbox.md.
//
// One profile aims to serve both consumer classes from one device:
//   • GameController / web / Steam (MFi) read input report 0x01 (built every frame).
//   • SDL HIDAPI (Dolphin, …) reads the GIP input report 0x20 (declared as a vendor
//     input below so macOS delivers it). GameController ignores the vendor usage
//     page, so it's harmless to stream unconditionally; a per-controller toggle in
//     the coordinator gates whether it's dispatched.
//
// SDL's modern GIP driver (SDL_hidapi_gip.c) reads EVERY input report off the device
// and parses byte 1 as a GIP "flags" field. On the real Series X, report 0x01 byte 1
// is the left-stick-X low byte; when it sets the FRAGMENT bit (0x80) SDL walks a
// fragment-reassembly path and NULL-derefs → Dolphin SIGSEGV. Apple's
// XboxOneHIDServicePlugin reads PID 0x0B13 by HARDCODED byte offsets (a shifted
// layout maps X→Guide etc.), so we can't insert a pad. Instead buildReport clears
// just bit 7 of byte 1: SDL's FRAGMENT bit is never set (no crash; our 0x01 is
// discarded as an unknown GIP message), while the layout stays byte-aligned for
// Apple. Cost: ≤0.2% of LX travel. See reference_xbox_sdl_gip_crash.
//
// Report 0x01 (17 bytes including ID) — real Series X layout:
//   0:      Report ID (0x01)
//   1..2:   LX  (UInt16 LE, 0..65535; byte 1 has bit 7 forced clear — see above)
//   3..4:   LY  (high = up; Apple maps high → +1)
//   5..6:   Z   = right stick X
//   7..8:   Rz  = right stick Y (high = up)
//   9..10:  Brake = LT, 10-bit LE in bits 0..9; bits 10..15 padding
//   11..12: Accelerator = RT, 10-bit LE; bits 10..15 padding
//   13:     hat low nibble (1=N, 2=NE, … 8=NW, 0=neutral), high nibble padding
//   14:     buttons 1..8 — A=bit0 B=bit1 (bit2 rsvd) X=bit3 Y=bit4 (bit5 rsvd) LB=bit6 RB=bit7
//   15:     buttons 9..15 — (bits0,1 rsvd) View=bit2 Menu=bit3 Guide=bit4 L3=bit5 R3=bit6, bit7 pad
//   16:     Share/Capture (Consumer Record 0x0B2) bit 0, bits 1..7 padding
struct XboxSeriesOutput: HIDOutputProfile {
    let vendorID: UInt16 = 0x045E
    let productID: UInt16 = 0x0B13
    let productName = "Xbox Wireless Controller"
    let manufacturer: String? = "Microsoft"
    let versionNumber: UInt16 = 0x050F

    var descriptor: Data { Self.descriptorBytes }

    // Stateful: the session tracks the Guide-button edge for the GIP 0x07 packet,
    // so each connection gets a fresh actor rather than sharing `self`.
    func makeSession() -> any HIDOutputSession { XboxSeriesSession() }

    // Real Series X BLE report descriptor (283 bytes) + a trailing vendor block
    // declaring the GIP input reports 0x07/0x20 so macOS delivers them to SDL.
    static let descriptorBytes: Data = Data([
        0x05, 0x01,             // Usage Page (Generic Desktop)
        0x09, 0x05,             // Usage (Game Pad)
        0xA1, 0x01,             // Collection (Application)
        0x85, 0x01,             //   Report ID (1)

        0x09, 0x01,             //   Usage (Pointer)
        0xA1, 0x00,             //   Collection (Physical)
        0x09, 0x30, 0x09, 0x31, //     Usage (X), Usage (Y)
        0x15, 0x00,
        0x27, 0xFF, 0xFF, 0x00, 0x00,
        0x95, 0x02,
        0x75, 0x10,
        0x81, 0x02,
        0xC0,                   //   End Collection

        0x09, 0x01,             //   Usage (Pointer)
        0xA1, 0x00,             //   Collection (Physical)
        0x09, 0x32, 0x09, 0x35, //     Usage (Z), Usage (Rz) — right stick
        0x15, 0x00,
        0x27, 0xFF, 0xFF, 0x00, 0x00,
        0x95, 0x02,
        0x75, 0x10,
        0x81, 0x02,
        0xC0,                   //   End Collection

        0x05, 0x02,             //   Usage Page (Simulation Controls)
        0x09, 0xC5,             //   Usage (Brake) — LT
        0x15, 0x00,
        0x26, 0xFF, 0x03,
        0x95, 0x01,
        0x75, 0x0A,
        0x81, 0x02,
        0x15, 0x00,
        0x25, 0x00,
        0x75, 0x06,
        0x95, 0x01,
        0x81, 0x03,

        0x05, 0x02,             //   Usage Page (Simulation Controls)
        0x09, 0xC4,             //   Usage (Accelerator) — RT
        0x15, 0x00,
        0x26, 0xFF, 0x03,
        0x95, 0x01,
        0x75, 0x0A,
        0x81, 0x02,
        0x15, 0x00,
        0x25, 0x00,
        0x75, 0x06,
        0x95, 0x01,
        0x81, 0x03,

        0x05, 0x01,             //   Usage Page (Generic Desktop)
        0x09, 0x39,             //   Usage (Hat switch)
        0x15, 0x01,
        0x25, 0x08,
        0x35, 0x00,
        0x46, 0x3B, 0x01,
        0x66, 0x14, 0x00,
        0x75, 0x04,
        0x95, 0x01,
        0x81, 0x42,
        0x75, 0x04,
        0x95, 0x01,
        0x15, 0x00,
        0x25, 0x00,
        0x35, 0x00,
        0x45, 0x00,
        0x65, 0x00,
        0x81, 0x03,

        0x05, 0x09,             //   Usage Page (Button)
        0x19, 0x01,             //   Usage Minimum (1)
        0x29, 0x0F,             //   Usage Maximum (15)
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x0F,
        0x81, 0x02,
        0x15, 0x00,
        0x25, 0x00,
        0x75, 0x01,
        0x95, 0x01,
        0x81, 0x03,

        0x05, 0x0C,             //   Usage Page (Consumer)
        0x0A, 0xB2, 0x00,       //   Usage (Record, 0x0B2) — Share
        0x15, 0x00,
        0x25, 0x01,
        0x95, 0x01,
        0x75, 0x01,
        0x81, 0x02,
        0x15, 0x00,
        0x25, 0x00,
        0x75, 0x07,
        0x95, 0x01,
        0x81, 0x03,

        0x05, 0x0F,             //   Usage Page (PID)
        0x09, 0x21,
        0x85, 0x03,             //   Report ID (3) — rumble output
        0xA1, 0x02,
        0x09, 0x97,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x04,
        0x95, 0x01,
        0x91, 0x02,
        0x15, 0x00,
        0x25, 0x00,
        0x75, 0x04,
        0x95, 0x01,
        0x91, 0x03,
        0x09, 0x70,
        0x15, 0x00,
        0x25, 0x64,
        0x75, 0x08,
        0x95, 0x04,
        0x91, 0x02,
        0x09, 0x50,
        0x66, 0x01, 0x10,
        0x55, 0x0E,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x01,
        0x91, 0x02,
        0x09, 0xA7,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x01,
        0x91, 0x02,
        0x65, 0x00,
        0x55, 0x00,
        0x09, 0x7C,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x01,
        0x91, 0x02,
        0xC0,                   //   End Collection (PID)

        // Vendor GIP input reports for SDL/HIDAPI (Dolphin). GameController ignores
        // the vendor usage page; SDL reads 0x20 as Xbox input and 0x07 as the Guide
        // virtual-key. macOS only delivers an input report ID to hidapi clients if
        // it's declared, so these must exist even though Apple's path ignores them.
        0x06, 0x00, 0xFF,       //   Usage Page (Vendor 0xFF00)
        0x15, 0x00,
        0x26, 0xFF, 0x00,       //   Logical Maximum (255)
        0x75, 0x08,             //   Report Size (8)
        0x85, 0x07,             //   Report ID (7) — GIP virtual-key (Guide)
        0x09, 0x07,
        0x95, 0x05,             //   Report Count (5)
        0x81, 0x02,             //   Input
        0x85, 0x20,             //   Report ID (0x20) — GIP_CMD_INPUT
        0x09, 0x20,
        0x95, 0x12,             //   Report Count (18)
        0x81, 0x02,             //   Input
        0xC0,                   // End Collection (Application)
    ])
}

// Per-connection session. Builds the faithful 0x01 input every frame and also
// the GIP 0x20 input + 0x07 Guide virtual-key for SDL/HIDAPI consumers.
actor XboxSeriesSession: HIDOutputSession {
    private var lastHome = false

    // Xbox sends one start frame and one stop frame ~1 s apart; the NS2 motor
    // times out after ~300 ms. Ask the coordinator to keep the motor alive
    // between host frames.
    nonisolated var refreshInterval: Duration? { .milliseconds(80) }

    // Two rumble paths reach this spoof:
    //
    // • Report 0x03 — macOS GCController.haptics drives the PID (Physical
    //   Interface) block declared in the descriptor:
    //     [id, enable(4-bit actuator mask), LT, RT, L, R, duration, delay, loop]
    //
    // • Report 0x09 — SDL's Xbox HIDAPI driver (Steam, Dolphin, …) sends GIP
    //   rumble. The faithful BLE descriptor does NOT declare 0x09, but CoreHID
    //   delivers the Set Report to us anyway (confirmed on hardware), so we just
    //   parse it — no descriptor change needed:
    //     [id, 0x00, 0x00, 0x09, 0x00, 0x0F, LT, RT, L, R, duration, delay, loop]
    //
    // Both send magnitudes as 0..100 percent (Xbox GIP convention); rescale to
    // 0..65535 so the NS2 LRA encoder reaches full amplitude. NS2 Pro has no
    // trigger motors, so fold trigger magnitudes into the main motor with max().
    nonisolated func parseRumble(type: HIDReportType, id: HIDReportID?, data: Data) -> RumbleCommand? {
        guard type == .output else { return nil }
        let b = data.startIndex
        let ltMag, rtMag, lMag, rMag: UInt8
        switch id?.rawValue {
        case 0x03:
            guard data.count >= 6 else { return nil }
            ltMag = data[b + 2]; rtMag = data[b + 3]
            lMag  = data[b + 4]; rMag  = data[b + 5]
        case 0x09:
            guard data.count >= 10 else { return nil }
            ltMag = data[b + 6]; rtMag = data[b + 7]
            lMag  = data[b + 8]; rMag  = data[b + 9]
        default:
            return nil
        }
        func scale(_ v: UInt8) -> UInt16 { UInt16(min(65535, Int(v) * 65535 / 100)) }
        return RumbleCommand(
            leftAmp: scale(max(ltMag, lMag)),
            rightAmp: scale(max(rtMag, rMag))
        )
    }

    func buildReport(_ state: ControllerState) async -> Data {
        let s = state.buttons
        let sh = state.shoulders
        var bytes = [UInt8](repeating: 0, count: 17)
        bytes[0] = 0x01  // Report ID

        // Centered 12-bit (-2047..2047) → unsigned 16-bit, neutral 0x8000.
        // `<< 4` widens 12-bit to ~16-bit (2047 → 0xFFF0, -2047 → 0x0010).
        func axis16(_ v: Int16) -> UInt16 {
            UInt16(clamping: 0x8000 + (Int(v) << 4))
        }
        let lx = axis16(state.leftStick.x)
        let ly = axis16(state.leftStick.y)
        let rx = axis16(state.rightStick.x)   // → Z
        let ry = axis16(state.rightStick.y)   // → Rz
        // byte 1 doubles as SDL's GIP "flags" field. Force bit 7 (GIP_FLAG_FRAGMENT)
        // clear so SDL never walks its fragment-reassembly path (which NULL-derefs
        // and crashes Dolphin). This is the LX low byte; clearing bit 7 costs
        // ≤128/65536 ≈ 0.2% of left-stick-X travel — imperceptible. The real
        // descriptor layout is otherwise untouched, so Apple's GCController mapping
        // stays byte-aligned. See reference_xbox_sdl_gip_crash.
        
        bytes[1] = UInt8(lx & 0xFF) & 0x7F; bytes[2] = UInt8(lx >> 8)
        bytes[3] = UInt8(ly & 0xFF); bytes[4] = UInt8(ly >> 8)
        bytes[5] = UInt8(rx & 0xFF); bytes[6] = UInt8(rx >> 8)
        bytes[7] = UInt8(ry & 0xFF); bytes[8] = UInt8(ry >> 8)

        // Brake (LT) / Accelerator (RT): 10-bit fields, each + 6 bits padding.
        let lt = UInt16(UInt32(sh.leftTriggerAnalog) * 1023 / 255)
        let rt = UInt16(UInt32(sh.rightTriggerAnalog) * 1023 / 255)
        bytes[9]  = UInt8(lt & 0xFF); bytes[10] = UInt8(lt >> 8)
        bytes[11] = UInt8(rt & 0xFF); bytes[12] = UInt8(rt >> 8)

        // Xbox hat: 1=N, 2=NE, 3=E, … 8=NW, 0=neutral.
        bytes[13] = Self.xboxHat(
            up: s.contains(.dpadUp),
            right: s.contains(.dpadRight),
            down: s.contains(.dpadDown),
            left: s.contains(.dpadLeft)
        ) & 0x0F

        // Buttons 1..8 (byte 14). Bits 2 and 5 are reserved/unused on a real pad.
        var b14: UInt8 = 0
        if s.contains(.b) { b14 |= 0x01 }  // button 1  = A (south)
        if s.contains(.a) { b14 |= 0x02 }  // button 2  = B (east)
        if s.contains(.y) { b14 |= 0x08 }  // button 4  = X (west)
        if s.contains(.x) { b14 |= 0x10 }  // button 5  = Y (north)
        if sh.leftBumper  { b14 |= 0x40 }  // button 7  = LB
        if sh.rightBumper { b14 |= 0x80 }  // button 8  = RB
        bytes[14] = b14

        // Buttons 9..15 (byte 15). Bits 0,1 reserved; bit 7 is the array pad.
        var b15: UInt8 = 0
        if s.contains(.minus)                        { b15 |= 0x04 }  // button 11 = View
        if s.contains(.start) || s.contains(.plus)   { b15 |= 0x08 }  // button 12 = Menu
        if s.contains(.home)                         { b15 |= 0x10 }  // button 13 = Guide
        if s.contains(.stickL)                       { b15 |= 0x20 }  // button 14 = L3
        if s.contains(.stickR)                       { b15 |= 0x40 }  // button 15 = R3
        bytes[15] = b15

        // byte 16: Share/Capture (Consumer Record).
        if s.contains(.capture) { bytes[16] |= 0x01 }
        return Data(bytes)
    }

    // GIP secondary stream for SDL/HIDAPI. The 0x20 input every frame, the 0x07
    // Guide virtual-key only on edges (an INTERNAL packet, so streaming it 70×/s
    // would be noise). GameController/Steam/browsers ignore the vendor usage page,
    // so this is harmless to them; the coordinator's per-controller toggle gates
    // whether it's dispatched at all.
    func buildSecondaryReports(_ state: ControllerState) async -> [Data] {
        var out = [gipInputReport(state)]
        let home = state.buttons.contains(.home)
        if home != lastHome {
            lastHome = home
            // GIP_CMD_GUIDE_BUTTON (0x07, SYSTEM). SDL only registers Guide when
            // the payload's 2nd byte == VK_LWIN (0x5B) and reads the pressed state
            // from byte 0 (GIP_HandleCommandGuideButtonStatus). So payload is
            // [state, 0x5B], length 2 — NOT [state, 0x00].
            out.append(Data([0x07, 0x20, 0x00, 0x02, home ? 0x01 : 0x00, 0x5B]))
        }
        return out
    }

    // GIP_CMD_INPUT (report 0x20), 19 bytes: [cmd, opts, seq, len, …15 payload].
    private func gipInputReport(_ state: ControllerState) -> Data {
        let s = state.buttons
        let sh = state.shoulders
        var bytes = [UInt8](repeating: 0, count: 19)
        bytes[0] = 0x20; bytes[1] = 0x00; bytes[2] = 0x00; bytes[3] = 0x0F

        var b0: UInt8 = 0
        if s.contains(.start) || s.contains(.plus) { b0 |= 0x04 }  // Menu
        if s.contains(.minus)                      { b0 |= 0x08 }  // View
        if s.contains(.b) { b0 |= 0x10 }  // A (south)
        if s.contains(.a) { b0 |= 0x20 }  // B (east)
        if s.contains(.y) { b0 |= 0x40 }  // X (west)
        if s.contains(.x) { b0 |= 0x80 }  // Y (north)
        bytes[4] = b0

        var b1: UInt8 = 0
        if s.contains(.dpadUp)    { b1 |= 0x01 }
        if s.contains(.dpadDown)  { b1 |= 0x02 }
        if s.contains(.dpadLeft)  { b1 |= 0x04 }
        if s.contains(.dpadRight) { b1 |= 0x08 }
        if sh.leftBumper          { b1 |= 0x10 }
        if sh.rightBumper         { b1 |= 0x20 }
        if s.contains(.stickL)    { b1 |= 0x40 }
        if s.contains(.stickR)    { b1 |= 0x80 }
        bytes[5] = b1

        let lt = UInt16(UInt32(sh.leftTriggerAnalog) * 1023 / 255)
        let rt = UInt16(UInt32(sh.rightTriggerAnalog) * 1023 / 255)
        bytes[6] = UInt8(lt & 0xFF); bytes[7] = UInt8(lt >> 8)
        bytes[8] = UInt8(rt & 0xFF); bytes[9] = UInt8(rt >> 8)

        // Sint16 LE center 0; SDL applies ~ to Y, so send down=positive.
        func gipAxis(_ value: Int) -> UInt16 { UInt16(bitPattern: Int16(clamping: value << 4)) }
        let lx = gipAxis(Int(state.leftStick.x))
        let ly = gipAxis(-Int(state.leftStick.y))
        let rx = gipAxis(Int(state.rightStick.x))
        let ry = gipAxis(-Int(state.rightStick.y))
        bytes[10] = UInt8(lx & 0xFF); bytes[11] = UInt8(lx >> 8)
        bytes[12] = UInt8(ly & 0xFF); bytes[13] = UInt8(ly >> 8)
        bytes[14] = UInt8(rx & 0xFF); bytes[15] = UInt8(rx >> 8)
        bytes[16] = UInt8(ry & 0xFF); bytes[17] = UInt8(ry >> 8)
        if s.contains(.capture) { bytes[18] |= 0x01 }  // Share
        return Data(bytes)
    }

    private static func xboxHat(up: Bool, right: Bool, down: Bool, left: Bool) -> UInt8 {
        switch (up, right, down, left) {
        case (true,  false, false, false): return 1
        case (true,  true,  false, false): return 2
        case (false, true,  false, false): return 3
        case (false, true,  true,  false): return 4
        case (false, false, true,  false): return 5
        case (false, false, true,  true ): return 6
        case (false, false, false, true ): return 7
        case (true,  false, false, true ): return 8
        default: return 0
        }
    }
}
