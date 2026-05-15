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

    // SwitchPro needs a stateful session: macOS's driver drives a subcommand
    // handshake and switches input report format from simple (0x3F) to full
    // (0x30) mid-stream. SwitchProSession holds that mode + reply counter.
    func makeSession() -> any HIDOutputSession { SwitchProSession(log: stderrLog) }
}
