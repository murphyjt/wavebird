import Foundation

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
    let manufacturer: String? = nil // Real controller shows up as '(null)'
    let versionNumber: UInt16 = 0x0001

    var descriptor: Data { Self.descriptorBytes }

    // Verbatim from a real Switch Pro Controller (extracted via ioreg).
    static let descriptorBytes: Data = Data([
        0x05, 0x01,              // Usage Page (Generic Desktop)
        0x09, 0x05,              // Usage (Game Pad)
        0xA1, 0x01,              // Collection (Application)
        0x06, 0x01, 0xFF,        //   Usage Page (Vendor 0xFF01)
        0x85, 0x21,              //   Report ID (33)
        0x09, 0x21,              //   Usage (0x21)
        0x75, 0x08,              //   Report Size (8)
        0x95, 0x30,              //   Report Count (48)
        0x81, 0x02,              //   Input (Data,Var,Abs)
        0x85, 0x30,              //   Report ID (48)
        0x09, 0x30,              //   Usage (0x30)
        0x75, 0x08,              //   Report Size (8)
        0x95, 0x30,              //   Report Count (48)
        0x81, 0x02,              //   Input (Data,Var,Abs)
        0x85, 0x31,              //   Report ID (49)
        0x09, 0x31,              //   Usage (0x31)
        0x75, 0x08,              //   Report Size (8)
        0x96, 0x69, 0x01,        //   Report Count (361)
        0x81, 0x02,              //   Input (Data,Var,Abs)
        0x85, 0x32,              //   Report ID (50)
        0x09, 0x32,              //   Usage (0x32)
        0x75, 0x08,              //   Report Size (8)
        0x96, 0x69, 0x01,        //   Report Count (361)
        0x81, 0x02,              //   Input (Data,Var,Abs)
        0x85, 0x33,              //   Report ID (51)
        0x09, 0x33,              //   Usage (0x33)
        0x75, 0x08,              //   Report Size (8)
        0x96, 0x69, 0x01,        //   Report Count (361)
        0x81, 0x02,              //   Input (Data,Var,Abs)
        0x85, 0x3F,              //   Report ID (63)
        0x05, 0x09,              //   Usage Page (Button)
        0x19, 0x01,              //   Usage Minimum (1)
        0x29, 0x10,              //   Usage Maximum (16)
        0x15, 0x00,              //   Logical Minimum (0)
        0x25, 0x01,              //   Logical Maximum (1)
        0x75, 0x01,              //   Report Size (1)
        0x95, 0x10,              //   Report Count (16)
        0x81, 0x02,              //   Input (Data,Var,Abs)
        0x05, 0x01,              //   Usage Page (Generic Desktop)
        0x09, 0x39,              //   Usage (Hat switch)
        0x15, 0x00,              //   Logical Minimum (0)
        0x25, 0x07,              //   Logical Maximum (7)
        0x75, 0x04,              //   Report Size (4)
        0x95, 0x01,              //   Report Count (1)
        0x81, 0x42,              //   Input (Data,Var,Abs,Null)
        0x05, 0x09,              //   Usage Page (Button)
        0x75, 0x04,              //   Report Size (4)
        0x95, 0x01,              //   Report Count (1)
        0x81, 0x01,              //   Input (Const)
        0x05, 0x01,              //   Usage Page (Generic Desktop)
        0x09, 0x30,              //   Usage (X)
        0x09, 0x31,              //   Usage (Y)
        0x09, 0x33,              //   Usage (Rx)
        0x09, 0x34,              //   Usage (Ry)
        0x16, 0x00, 0x00,        //   Logical Minimum (0)
        0x27, 0xFF, 0xFF, 0x00, 0x00, // Logical Maximum (65535)
        0x75, 0x10,              //   Report Size (16)
        0x95, 0x04,              //   Report Count (4)
        0x81, 0x02,              //   Input (Data,Var,Abs)
        0x06, 0x01, 0xFF,        //   Usage Page (Vendor 0xFF01)
        0x85, 0x81,              //   Report ID (129)
        0x09, 0x81,              //   Usage (0x81)
        0x75, 0x08,              //   Report Size (8)
        0x95, 0x3F,              //   Report Count (63)
        0x81, 0x02,              //   Input (Data,Var,Abs)
        0x85, 0x01,              //   Report ID (1)
        0x09, 0x01,              //   Usage (0x01)
        0x75, 0x08,              //   Report Size (8)
        0x95, 0x30,              //   Report Count (48)
        0x91, 0x02,              //   Output (Data,Var,Abs)
        0x85, 0x10,              //   Report ID (16)
        0x09, 0x10,              //   Usage (0x10)
        0x75, 0x08,              //   Report Size (8)
        0x95, 0x30,              //   Report Count (48)
        0x91, 0x02,              //   Output (Data,Var,Abs)
        0x85, 0x11,              //   Report ID (17)
        0x09, 0x11,              //   Usage (0x11)
        0x75, 0x08,              //   Report Size (8)
        0x95, 0x30,              //   Report Count (48)
        0x91, 0x02,              //   Output (Data,Var,Abs)
        0x85, 0x12,              //   Report ID (18)
        0x09, 0x12,              //   Usage (0x12)
        0x75, 0x08,              //   Report Size (8)
        0x95, 0x30,              //   Report Count (48)
        0x91, 0x02,              //   Output (Data,Var,Abs)
        0x85, 0x80,              //   Report ID (128)
        0x09, 0x80,              //   Usage (0x80)
        0x75, 0x08,              //   Report Size (8)
        0x95, 0x3F,              //   Report Count (63)
        0x91, 0x02,              //   Output (Data,Var,Abs)
        0xC0                     // End Collection
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
