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
// SDL/Steam on the GIP (USB) route is intentionally NOT served here right now —
// this profile targets faithful BLE/GameController behaviour. The earlier GIP
// reports (0x20 input, 0x07 virtual-key) live in git history if revived.
//
// Report 0x01 (17 bytes including ID) — real Series X layout:
//   0:      Report ID (0x01)
//   1..2:   LX  (UInt16 LE, 0..65535)
//   3..4:   LY  (high = up; Apple maps high → +1)
//   5..6:   Z   = right stick X
//   7..8:   Rz  = right stick Y (high = up)
//   9..10:  Brake = LT, 10-bit LE in bits 0..9; bits 10..15 padding
//   11..12: Accelerator = RT, 10-bit LE; bits 10..15 padding
//   13:     hat low nibble (1=N, 2=NE, … 8=NW, 0=neutral), high nibble padding
//   14:     buttons 1..8 — A=bit0 B=bit1 (bit2 rsvd) X=bit3 Y=bit4 (bit5 rsvd) LB=bit6 RB=bit7
//   15:     buttons 9..15 — (bits0,1 rsvd) View=bit2 Menu=bit3 Guide=bit4 L3=bit5 R3=bit6, bit7 pad
//   16:     Share/Capture (Consumer Record 0x0B2) bit 0, bits 1..7 padding
struct XboxSeriesOutput: HIDOutputProfile, HIDOutputSession {
    let vendorID: UInt16 = 0x045E
    let productID: UInt16 = 0x0B13
    let productName = "Xbox Wireless Controller"
    let manufacturer: String? = "Microsoft"
    let versionNumber: UInt16 = 0x050F

    var descriptor: Data { Self.descriptorBytes }

    func makeSession() -> any HIDOutputSession { self }

    // Xbox sends one start frame and one stop frame ~1 s apart; the NS2
    // motor times out after ~300 ms. Ask the coordinator to keep the motor
    // alive between host frames.
    var refreshInterval: Duration? { .milliseconds(80) }

    // Verbatim real Series X BLE report descriptor (283 bytes).
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
        0xC0,                   //   End Collection
        0xC0,                   // End Collection
    ])

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
    func parseRumble(type: HIDReportType, id: HIDReportID?, data: Data) -> RumbleCommand? {
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
        bytes[1] = UInt8(lx & 0xFF); bytes[2] = UInt8(lx >> 8)
        bytes[3] = UInt8(ly & 0xFF); bytes[4] = UInt8(ly >> 8)
        bytes[5] = UInt8(rx & 0xFF); bytes[6] = UInt8(rx >> 8)
        bytes[7] = UInt8(ry & 0xFF); bytes[8] = UInt8(ry >> 8)

        // Brake (LT) / Accelerator (RT): 10-bit fields, each + 6 bits padding.
        let lt = UInt16(UInt32(sh.leftTriggerAnalog) * 1023 / 255)
        let rt = UInt16(UInt32(sh.rightTriggerAnalog) * 1023 / 255)
        bytes[9]  = UInt8(lt & 0xFF); bytes[10] = UInt8(lt >> 8)
        bytes[11] = UInt8(rt & 0xFF); bytes[12] = UInt8(rt >> 8)

        // Xbox hat: 1=N, 2=NE, 3=E, … 8=NW, 0=neutral.
        bytes[13] = xboxHat(
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

    private func xboxHat(up: Bool, right: Bool, down: Bool, left: Bool) -> UInt8 {
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
