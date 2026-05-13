import Foundation

// HIDOutputProfile decides what virtual HID device we present to macOS — its
// VID/PID, descriptor, and how each ControllerState is encoded into a HID
// report. The default `.native` mode delegates to the connected controller's
// own ControllerProfile (so the GC controller reports as a GC controller, the
// Pro as a Pro). The other modes spoof a well-known third-party controller
// that GameController.framework, web Gamepad API, and most games already
// have built-in mappings for.
//
// Spoofs map shoulders/triggers via ControllerProfile.standardShoulders so
// GC's ZL/Z (digital top) land on the bumpers and L/R (analog clicks) land on
// the triggers — physically correct for each controller despite ButtonSet's
// Nintendo-flavored naming.

enum HIDOutputMode: String, CaseIterable, Sendable, Hashable {
    case native
    case switchPro
    case dualShock4
    case dualSense
    case xboxSeries

    var displayName: String {
        switch self {
        case .native:      return "Native (Switch 2)"
        case .switchPro:   return "Switch Pro Controller"
        case .dualShock4:  return "DualShock 4"
        case .dualSense:   return "DualSense"
        case .xboxSeries:  return "Xbox Wireless Controller"
        }
    }
}

protocol HIDOutputProfile: Sendable {
    var vendorID: UInt16 { get }
    var productID: UInt16 { get }
    var productName: String { get }
    var manufacturer: String { get }
    var descriptor: Data { get }
    func buildReport(_ state: ControllerState, source: any ControllerProfile) -> Data
}

// MARK: - Native passthrough

// Delegates to a ControllerProfile so each connected controller advertises
// itself with its real VID/PID and descriptor.
struct NativeOutput: HIDOutputProfile {
    let profile: any ControllerProfile

    var vendorID: UInt16 { profile.hidVendorID }
    var productID: UInt16 { profile.hidProductID }
    var productName: String { profile.name }
    var manufacturer: String { "Nintendo" }
    var descriptor: Data { profile.hidDescriptor }

    func buildReport(_ state: ControllerState, source: any ControllerProfile) -> Data {
        profile.buildHIDReport(state)
    }
}

// MARK: - Stick / hat helpers

private enum SpoofEncode {
    // Map Int8 (-128..127) to UInt8 (0..255) with neutral at 128.
    static func stickX(_ v: Int8) -> UInt8 { UInt8(clamping: Int(v) + 128) }
    // Same as stickX but inverted — our parser produces "positive Y = up"
    // (game-friendly), while real DS4/DualSense/Xbox controllers send HID-
    // convention "positive Y = down".
    static func stickY(_ v: Int8) -> UInt8 { UInt8(clamping: 128 - Int(v)) }

    // Hat encoding. neutral varies by descriptor: DS4/DualSense use 0x08, while
    // standard HID null state is 0x0F.
    static func hat(up: Bool, right: Bool, down: Bool, left: Bool, neutral: UInt8) -> UInt8 {
        switch (up, right, down, left) {
        case (true,  false, false, false): return 0
        case (true,  true,  false, false): return 1
        case (false, true,  false, false): return 2
        case (false, true,  true,  false): return 3
        case (false, false, true,  false): return 4
        case (false, false, true,  true ): return 5
        case (false, false, false, true ): return 6
        case (true,  false, false, true ): return 7
        default: return neutral
        }
    }
}

// MARK: - DualShock 4

// Sony DualShock 4 (CUH-ZCT1, VID 0x054C / PID 0x05C4). Report ID 0x01 matches
// the real USB input report: 63 bytes of payload plus the leading report ID.
//
// Report (64 bytes including ID):
//   0: Report ID (0x01)
//   1: LX  (UInt8 0..255)
//   2: LY
//   3: RX
//   4: RY
//   5: hat low nibble (0..7, 8=neutral) | face buttons high nibble
//        bit 4 = SQUARE, 5 = CROSS, 6 = CIRCLE, 7 = TRIANGLE
//   6: L1=0, R1=1, L2=2, R2=3, SHARE=4, OPTIONS=5, L3=6, R3=7
//   7: PS=0, TPad=1, counter bits 2..7
//   8: L2 analog
//   9: R2 analog
//   10..63: vendor-defined fields, left at 0
struct DualShock4Output: HIDOutputProfile {
    let vendorID: UInt16 = 0x054C
    let productID: UInt16 = 0x05C4
    let productName = "Wireless Controller"
    let manufacturer = "Sony Interactive Entertainment"

    var descriptor: Data { Self.descriptorBytes }

    static let descriptorBytes: Data = Data([
        0x05, 0x01,
        0x09, 0x05,
        0xA1, 0x01,
        0x85, 0x01,

        0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x04,
        0x81, 0x02,

        0x09, 0x39,
        0x15, 0x00,
        0x25, 0x07,
        0x35, 0x00,
        0x46, 0x3B, 0x01,
        0x65, 0x14,
        0x75, 0x04,
        0x95, 0x01,
        0x81, 0x42,
        0x65, 0x00,

        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x0E,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x0E,
        0x81, 0x02,

        0x06, 0x00, 0xFF,
        0x09, 0x20,
        0x75, 0x06,
        0x95, 0x01,
        0x15, 0x00,
        0x25, 0x7F,
        0x81, 0x02,

        0x05, 0x01,
        0x09, 0x33,
        0x09, 0x34,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x02,
        0x81, 0x02,

        0x06, 0x00, 0xFF,
        0x09, 0x21,
        0x95, 0x36,
        0x81, 0x02,

        0xC0,
    ])

    func buildReport(_ state: ControllerState, source: any ControllerProfile) -> Data {
        let s = state.buttons
        let sh = source.standardShoulders(state)
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x01
        bytes[1] = SpoofEncode.stickX(state.leftStick.x)
        bytes[2] = SpoofEncode.stickY(state.leftStick.y)
        bytes[3] = SpoofEncode.stickX(state.rightStick.x)
        bytes[4] = SpoofEncode.stickY(state.rightStick.y)

        let hat = SpoofEncode.hat(
            up: s.contains(.dpadUp),
            right: s.contains(.dpadRight),
            down: s.contains(.dpadDown),
            left: s.contains(.dpadLeft),
            neutral: 0x08
        )
        var b5: UInt8 = hat & 0x0F
        if s.contains(.y) { b5 |= 0x10 }  // SQUARE (west)
        if s.contains(.b) { b5 |= 0x20 }  // CROSS  (south)
        if s.contains(.a) { b5 |= 0x40 }  // CIRCLE (east)
        if s.contains(.x) { b5 |= 0x80 }  // TRIANGLE (north)
        bytes[5] = b5

        var b6: UInt8 = 0
        if sh.leftBumper            { b6 |= 0x01 }  // L1
        if sh.rightBumper           { b6 |= 0x02 }  // R1
        if sh.leftTriggerDigital    { b6 |= 0x04 }  // L2 digital
        if sh.rightTriggerDigital   { b6 |= 0x08 }  // R2 digital
        if s.contains(.capture) || s.contains(.minus) { b6 |= 0x10 }  // SHARE
        if s.contains(.start)   || s.contains(.plus)  { b6 |= 0x20 }  // OPTIONS
        if s.contains(.stickL)      { b6 |= 0x40 }  // L3
        if s.contains(.stickR)      { b6 |= 0x80 }  // R3
        bytes[6] = b6

        var b7: UInt8 = 0
        if s.contains(.home) { b7 |= 0x01 }  // PS
        if s.contains(.c)    { b7 |= 0x02 }  // TPad (GC's C lands here)
        bytes[7] = b7

        bytes[8] = sh.leftTriggerAnalog
        bytes[9] = sh.rightTriggerAnalog
        return Data(bytes)
    }
}

// MARK: - DualSense

// Sony DualSense (CFI-ZCT1, VID 0x054C / PID 0x0CE6). Report ID 0x01 matches
// the real USB input report: 63 bytes of payload plus the leading report ID.
//
// Report (64 bytes including ID):
//   0:    Report ID (0x01)
//   1..4: LX, LY, RX, RY (UInt8 0..255)
//   5:    L2 analog
//   6:    R2 analog
//   7:    sequence / vendor byte (left at 0)
//   8:    hat low nibble | face buttons high nibble (same shape as DS4)
//   9:    L1=0, R1=1, L2=2, R2=3, CREATE=4, OPTIONS=5, L3=6, R3=7
//   10:   PS=0, TPad=1, Mute=2, vendor bits 3..7
//   11..63: vendor-defined fields, left at 0
struct DualSenseOutput: HIDOutputProfile {
    let vendorID: UInt16 = 0x054C
    let productID: UInt16 = 0x0CE6
    let productName = "DualSense Wireless Controller"
    let manufacturer = "Sony Interactive Entertainment"

    var descriptor: Data { Self.descriptorBytes }

    static let descriptorBytes: Data = Data([
        0x05, 0x01,
        0x09, 0x05,
        0xA1, 0x01,
        0x85, 0x01,        // Report ID (0x01)

        0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
        0x09, 0x33, 0x09, 0x34,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x06,
        0x81, 0x02,

        0x06, 0x00, 0xFF,
        0x09, 0x20,
        0x95, 0x01,
        0x81, 0x02,

        0x05, 0x01,
        0x09, 0x39,
        0x15, 0x00,
        0x25, 0x07,
        0x35, 0x00,
        0x46, 0x3B, 0x01,
        0x65, 0x14,
        0x75, 0x04,
        0x95, 0x01,
        0x81, 0x42,
        0x65, 0x00,

        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x0F,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x0F,
        0x81, 0x02,

        0x06, 0x00, 0xFF,
        0x09, 0x21,
        0x95, 0x0D,
        0x81, 0x02,

        0x06, 0x00, 0xFF,
        0x09, 0x22,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x34,
        0x81, 0x02,

        0xC0,
    ])

    func buildReport(_ state: ControllerState, source: any ControllerProfile) -> Data {
        let s = state.buttons
        let sh = source.standardShoulders(state)
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0]  = 0x01  // Report ID
        bytes[1]  = SpoofEncode.stickX(state.leftStick.x)
        bytes[2]  = SpoofEncode.stickY(state.leftStick.y)
        bytes[3]  = SpoofEncode.stickX(state.rightStick.x)
        bytes[4]  = SpoofEncode.stickY(state.rightStick.y)
        bytes[5]  = sh.leftTriggerAnalog
        bytes[6]  = sh.rightTriggerAnalog
        bytes[7]  = 0  // counter

        let hat = SpoofEncode.hat(
            up: s.contains(.dpadUp),
            right: s.contains(.dpadRight),
            down: s.contains(.dpadDown),
            left: s.contains(.dpadLeft),
            neutral: 0x08
        )
        var b8: UInt8 = hat & 0x0F
        if s.contains(.y) { b8 |= 0x10 }
        if s.contains(.b) { b8 |= 0x20 }
        if s.contains(.a) { b8 |= 0x40 }
        if s.contains(.x) { b8 |= 0x80 }
        bytes[8] = b8

        var b9: UInt8 = 0
        if sh.leftBumper           { b9 |= 0x01 }  // L1
        if sh.rightBumper          { b9 |= 0x02 }  // R1
        if sh.leftTriggerDigital   { b9 |= 0x04 }  // L2
        if sh.rightTriggerDigital  { b9 |= 0x08 }  // R2
        if s.contains(.capture) || s.contains(.minus) { b9 |= 0x10 }  // CREATE
        if s.contains(.start)   || s.contains(.plus)  { b9 |= 0x20 }  // OPTIONS
        if s.contains(.stickL)     { b9 |= 0x40 }
        if s.contains(.stickR)     { b9 |= 0x80 }
        bytes[9] = b9

        var b10: UInt8 = 0
        if s.contains(.home) { b10 |= 0x01 }
        if s.contains(.c)    { b10 |= 0x02 }
        bytes[10] = b10
        return Data(bytes)
    }
}

// MARK: - Xbox Wireless Controller (Series X|S, Bluetooth)

// Microsoft Xbox Wireless Controller Bluetooth variant (VID 0x045E / PID
// 0x0B13). The actual Xbox 360 controller is XInput, not HID, so it can't be
// spoofed via a virtual HID device — we use the Series controller's BT profile.
// Real device uses HID Report ID 0x01; Chrome's gamepad mapper keys off this.
//
// Sticks are 16-bit unsigned (0..65535) per the real Xbox BT descriptor —
// some browser mappers strictly expect this width and fail to register input
// against the 8-bit signed sticks I tried first.
//
// Report 0x01 (16 bytes including ID):
//   0:     Report ID (0x01)
//   1..2:  LX low/high (UInt16 LE, 0..65535)
//   3..4:  LY
//   5..6:  RX
//   7..8:  RY
//   9..10: LT, 10-bit LE in bits 0..9; bits 10..15 padding
//   11..12: RT, 10-bit LE in bits 0..9; bits 10..15 padding
//   13:    low nibble hat (1=N, 2=NE, ... 8=NW, 0=neutral), high nibble padding
//   14:    A=0, B=1, X=2, Y=3, LB=4, RB=5, View=6, Menu=7
//   15:    L3=0, R3=1, bits 2..7 padding
struct XboxSeriesOutput: HIDOutputProfile {
    let vendorID: UInt16 = 0x045E
    let productID: UInt16 = 0x0B13
    let productName = "Xbox Wireless Controller"
    let manufacturer = "Microsoft"

    var descriptor: Data { Self.descriptorBytes }

    static let descriptorBytes: Data = Data([
        0x05, 0x01,
        0x09, 0x05,
        0xA1, 0x01,
        0x85, 0x01,

        0x09, 0x01,
        0xA1, 0x00,
        0x09, 0x30, 0x09, 0x31,
        0x15, 0x00,
        0x27, 0xFF, 0xFF, 0x00, 0x00,
        0x95, 0x02,
        0x75, 0x10,
        0x81, 0x02,
        0xC0,

        0x09, 0x01,
        0xA1, 0x00,
        0x09, 0x33, 0x09, 0x34,
        0x15, 0x00,
        0x27, 0xFF, 0xFF, 0x00, 0x00,
        0x95, 0x02,
        0x75, 0x10,
        0x81, 0x02,
        0xC0,

        0x05, 0x01,
        0x09, 0x32,
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

        0x05, 0x01,
        0x09, 0x35,
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

        0x05, 0x01,
        0x09, 0x39,
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

        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x0A,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x0A,
        0x81, 0x02,
        0x15, 0x00,
        0x25, 0x00,
        0x75, 0x06,
        0x95, 0x01,
        0x81, 0x03,

        0x05, 0x01,
        0x09, 0x80,
        0x85, 0x02,
        0xA1, 0x00,
        0x09, 0x85,
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
        0xC0,

        0x05, 0x0F,
        0x09, 0x21,
        0x85, 0x03,
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
        0xC0,

        0x85, 0x04,
        0x05, 0x06,
        0x09, 0x20,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x01,
        0x81, 0x02,

        0xC0,
    ])

    func buildReport(_ state: ControllerState, source: any ControllerProfile) -> Data {
        let s = state.buttons
        let sh = source.standardShoulders(state)
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x01  // Report ID

        func axis16(_ v: Int8, invert: Bool = false) -> UInt16 {
            let value = invert ? -Int(v) : Int(v)
            if value >= 0 {
                return UInt16(clamping: 0x8000 + value * 258)
            } else {
                return UInt16(clamping: 0x8000 + value * 256)
            }
        }
        let lx = axis16(state.leftStick.x)
        let ly = axis16(state.leftStick.y, invert: true)
        let rx = axis16(state.rightStick.x)
        let ry = axis16(state.rightStick.y, invert: true)
        bytes[1] = UInt8(lx & 0xFF); bytes[2] = UInt8(lx >> 8)
        bytes[3] = UInt8(ly & 0xFF); bytes[4] = UInt8(ly >> 8)
        bytes[5] = UInt8(rx & 0xFF); bytes[6] = UInt8(rx >> 8)
        bytes[7] = UInt8(ry & 0xFF); bytes[8] = UInt8(ry >> 8)

        // Triggers are 10-bit fields, each followed by 6 bits of padding.
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

        var b14: UInt8 = 0
        if s.contains(.b) { b14 |= 0x01 }  // bit 0 = A (south)
        if s.contains(.a) { b14 |= 0x02 }  // bit 1 = B (east)
        if s.contains(.y) { b14 |= 0x04 }  // bit 2 = X (west)
        if s.contains(.x) { b14 |= 0x08 }  // bit 3 = Y (north)
        if sh.leftBumper  { b14 |= 0x10 }  // bit 4 = LB
        if sh.rightBumper { b14 |= 0x20 }  // bit 5 = RB
        if s.contains(.capture) || s.contains(.minus) { b14 |= 0x40 }  // View
        if s.contains(.start)   || s.contains(.plus)  { b14 |= 0x80 }  // Menu
        bytes[14] = b14

        var b15: UInt8 = 0
        if s.contains(.stickL) { b15 |= 0x01 }  // L3
        if s.contains(.stickR) { b15 |= 0x02 }  // R3
        bytes[15] = b15
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

// MARK: - Switch Pro Controller (Switch 1)

// Nintendo Switch Pro Controller (VID 0x057E / PID 0x2009, BT). macOS has
// shipped first-class GameController.framework support since Big Sur.
//
// Descriptor is byte-verbatim from a real Switch Pro Controller paired to this
// machine (extracted via `ioreg -lw0 -c IOHIDDevice` → ReportDescriptor). The
// real controller advertises five input reports (one simple-mode + four vendor
// "full mode"/NFC) and four vendor output reports (subcommand + rumble). macOS's
// driver normally drives the full-mode 0x30 protocol via subcommand handshake;
// our virtual device ignores those outputs and only ever sends the simple-mode
// report 0x3F, which is the standard HID fallback the same controller produces
// before subcommands put it into 0x30 mode.
//
// Report 0x3F layout (12 bytes including ID):
//   0:      Report ID (0x3F)
//   1..2:   16 buttons (LE):
//             bit 0  B            bit 8  Minus
//             bit 1  A            bit 9  Plus
//             bit 2  Y            bit 10 L-stick click
//             bit 3  X            bit 11 R-stick click
//             bit 4  L            bit 12 Home
//             bit 5  R            bit 13 Capture
//             bit 6  ZL           bit 14 (reserved)
//             bit 7  ZR           bit 15 (reserved)
//   3:      lo-nibble = hat (0=N, 1=NE, 2=E, 3=SE, 4=S, 5=SW, 6=W, 7=NW, 8=null)
//           hi-nibble = padding (constant 0)
//   4..5:   X  (UInt16 LE, 0..65535, neutral 0x8000)   — left stick X
//   6..7:   Y  (UInt16 LE)                             — left stick Y  (HID Y=down)
//   8..9:   Rx (UInt16 LE)                             — right stick X
//   10..11: Ry (UInt16 LE)                             — right stick Y (HID Y=down)
struct SwitchProOutput: HIDOutputProfile {
    let vendorID: UInt16 = 0x057E
    let productID: UInt16 = 0x2009
    let productName = "Pro Controller"
    let manufacturer = "Nintendo"

    var descriptor: Data { Self.descriptorBytes }

    // Verbatim from /dev real device — do not edit without re-pulling.
    static let descriptorBytes: Data = Data([
        0x05, 0x01,              // Usage Page (Generic Desktop)
        0x09, 0x05,              // Usage (Game Pad)
        0xA1, 0x01,              // Collection (Application)

        // -- Vendor-defined input reports (declared so Apple's driver may probe;
        //    we never produce these). All on Usage Page 0xFF01.
        0x06, 0x01, 0xFF,        //   Usage Page (Vendor 0xFF01)
        0x85, 0x21,              //   Report ID 0x21  — subcommand reply (48B)
        0x09, 0x21, 0x75, 0x08, 0x95, 0x30, 0x81, 0x02,
        0x85, 0x30,              //   Report ID 0x30  — full-mode input (48B)
        0x09, 0x30, 0x75, 0x08, 0x95, 0x30, 0x81, 0x02,
        0x85, 0x31,              //   Report ID 0x31  — NFC/IR data (361B)
        0x09, 0x31, 0x75, 0x08, 0x96, 0x69, 0x01, 0x81, 0x02,
        0x85, 0x32,              //   Report ID 0x32  — NFC/IR data (361B)
        0x09, 0x32, 0x75, 0x08, 0x96, 0x69, 0x01, 0x81, 0x02,
        0x85, 0x33,              //   Report ID 0x33  — NFC/IR data (361B)
        0x09, 0x33, 0x75, 0x08, 0x96, 0x69, 0x01, 0x81, 0x02,

        // -- Report 0x3F: simple HID input (the only one we actually send).
        0x85, 0x3F,              //   Report ID (63)
        0x05, 0x09,              //   Usage Page (Button)
        0x19, 0x01,              //   Usage Minimum (Button 1)
        0x29, 0x10,              //   Usage Maximum (Button 16)
        0x15, 0x00,              //   Logical Minimum (0)
        0x25, 0x01,              //   Logical Maximum (1)
        0x75, 0x01,              //   Report Size (1)
        0x95, 0x10,              //   Report Count (16)              → bytes 1..2
        0x81, 0x02,              //   Input (Data, Var, Abs)

        0x05, 0x01,              //   Usage Page (Generic Desktop)
        0x09, 0x39,              //   Usage (Hat switch)
        0x15, 0x00,              //   Logical Minimum (0)
        0x25, 0x07,              //   Logical Maximum (7)
        0x75, 0x04,              //   Report Size (4)
        0x95, 0x01,              //   Report Count (1)               → byte 3 lo-nibble
        0x81, 0x42,              //   Input (Data, Var, Abs, Null state)

        0x05, 0x09,              //   Usage Page (Button) (irrelevant — constant)
        0x75, 0x04,              //   Report Size (4)
        0x95, 0x01,              //   Report Count (1)               → byte 3 hi-nibble
        0x81, 0x01,              //   Input (Const)

        0x05, 0x01,              //   Usage Page (Generic Desktop)
        0x09, 0x30,              //   Usage (X)                      → bytes 4..5
        0x09, 0x31,              //   Usage (Y)                      → bytes 6..7
        0x09, 0x33,              //   Usage (Rx)                     → bytes 8..9
        0x09, 0x34,              //   Usage (Ry)                     → bytes 10..11
        0x16, 0x00, 0x00,        //   Logical Minimum (0)
        0x27, 0xFF, 0xFF, 0x00, 0x00, // Logical Maximum (65535)
        0x75, 0x10,              //   Report Size (16)
        0x95, 0x04,              //   Report Count (4)
        0x81, 0x02,              //   Input (Data, Var, Abs)

        // -- Vendor-defined output reports (declared but ignored by our delegate;
        //    Apple's driver may try to send subcommands and we silently drop them).
        0x06, 0x01, 0xFF,        //   Usage Page (Vendor 0xFF01)
        0x85, 0x01,              //   Report ID 0x01  — rumble + subcommand (48B)
        0x09, 0x01, 0x75, 0x08, 0x95, 0x30, 0x91, 0x02,
        0x85, 0x10,              //   Report ID 0x10  — rumble only (48B)
        0x09, 0x10, 0x75, 0x08, 0x95, 0x30, 0x91, 0x02,
        0x85, 0x11,              //   Report ID 0x11  — request NFC/IR (48B)
        0x09, 0x11, 0x75, 0x08, 0x95, 0x30, 0x91, 0x02,
        0x85, 0x12,              //   Report ID 0x12  — request NFC/IR (48B)
        0x09, 0x12, 0x75, 0x08, 0x95, 0x30, 0x91, 0x02,

        0xC0,                    // End Collection
    ])

    func buildReport(_ state: ControllerState, source: any ControllerProfile) -> Data {
        let s = state.buttons
        let sh = source.standardShoulders(state)
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = 0x3F  // Report ID — simple HID input mode

        // Buttons: 16-bit LE bitmap. Switch button labels (A=east, B=south,
        // X=north, Y=west). Shoulder roles via standardShoulders so GC's
        // ZL/Z map to L/R (top digital) and L/R analog clicks map to ZL/ZR.
        var b: UInt16 = 0
        if s.contains(.b)         { b |= 1 << 0 }
        if s.contains(.a)         { b |= 1 << 1 }
        if s.contains(.y)         { b |= 1 << 2 }
        if s.contains(.x)         { b |= 1 << 3 }
        if sh.leftBumper          { b |= 1 << 4 }   // L
        if sh.rightBumper         { b |= 1 << 5 }   // R
        if sh.leftTriggerDigital  { b |= 1 << 6 }   // ZL
        if sh.rightTriggerDigital { b |= 1 << 7 }   // ZR
        if s.contains(.minus)     { b |= 1 << 8 }
        if s.contains(.plus) || s.contains(.start) { b |= 1 << 9 }
        if s.contains(.stickL)    { b |= 1 << 10 }
        if s.contains(.stickR)    { b |= 1 << 11 }
        if s.contains(.home)      { b |= 1 << 12 }
        if s.contains(.capture)   { b |= 1 << 13 }
        bytes[1] = UInt8(b & 0xFF)
        bytes[2] = UInt8(b >> 8)

        // Hat: 0=N, 1=NE, … 7=NW, 8=null. Real device uses 8 for neutral.
        bytes[3] = SpoofEncode.hat(
            up: s.contains(.dpadUp),
            right: s.contains(.dpadRight),
            down: s.contains(.dpadDown),
            left: s.contains(.dpadLeft),
            neutral: 0x08
        ) & 0x0F

        // Sticks: 16-bit unsigned 0..65535, neutral 0x8000. Y inverted because
        // our internal convention is +Y=up; HID/Switch convention is +Y=down.
        let lx = Self.axis16(state.leftStick.x)
        let ly = Self.axis16(-Int(state.leftStick.y))
        let rx = Self.axis16(state.rightStick.x)
        let ry = Self.axis16(-Int(state.rightStick.y))
        bytes[4]  = UInt8(lx & 0xFF); bytes[5]  = UInt8(lx >> 8)
        bytes[6]  = UInt8(ly & 0xFF); bytes[7]  = UInt8(ly >> 8)
        bytes[8]  = UInt8(rx & 0xFF); bytes[9]  = UInt8(rx >> 8)
        bytes[10] = UInt8(ry & 0xFF); bytes[11] = UInt8(ry >> 8)
        return Data(bytes)
    }

    // Map Int8 (-128..127) → UInt16 (0..65535), neutral at 0x8000.
    // Positive side uses *258 so +127 lands at 0xFFFF (full range); negative
    // side uses *256 so -128 lands at 0x0000 — same shape as the Xbox encoder.
    private static func axis16(_ v: Int8) -> UInt16 { axis16(Int(v)) }
    private static func axis16(_ value: Int) -> UInt16 {
        if value >= 0 { return UInt16(clamping: 0x8000 + value * 258) }
        else          { return UInt16(clamping: 0x8000 + value * 256) }
    }
}
