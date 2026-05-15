import Foundation

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
struct DualSenseOutput: HIDOutputProfile, HIDOutputSession {
    let vendorID: UInt16 = 0x054C
    let productID: UInt16 = 0x0CE6
    let productName = "DualSense Wireless Controller"
    let manufacturer: String? = "Sony Interactive Entertainment"
    let versionNumber: UInt16 = 0x0100

    var descriptor: Data { Self.descriptorBytes }

    func makeSession() -> any HIDOutputSession { self }

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

    func buildReport(_ state: ControllerState, source: any ControllerProfile) async -> Data {
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
