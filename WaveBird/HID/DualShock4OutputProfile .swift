import Foundation

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
struct DualShock4Output: HIDOutputProfile, HIDOutputSession {
    let vendorID: UInt16 = 0x054C
    let productID: UInt16 = 0x05C4
    let productName = "Wireless Controller"
    let manufacturer: String? = "Sony Interactive Entertainment"
    let versionNumber: UInt16 = 0x0100

    var descriptor: Data { Self.descriptorBytes }

    func makeSession() -> any HIDOutputSession { self }

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

    func buildReport(_ state: ControllerState) async -> Data {
        let s = state.buttons
        let sh = state.shoulders
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
