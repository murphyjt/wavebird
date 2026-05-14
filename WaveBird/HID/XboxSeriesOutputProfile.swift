import Foundation

// Microsoft Xbox Wireless Controller, VID 0x045E / PID 0x0B13 (BLE Series X).
//
// PID 0x0B13 is the BLE Series X PID. Apple's XboxOneHIDServicePlugin takes
// the BLE code path for this PID — no GIP handshake required — and creates
// a GCController immediately. (USB PIDs like 0x0B12 trigger GIP init, which
// blocks until the virtual device responds with a GIP status packet.)
//
// SDL on macOS reads the GCController via its MFI backend. Apple re-presents
// our virtual device through the GCController layer as BLE 0x0B13 regardless
// of what transport we set on the HIDVirtualDevice, so Steam and SDL both see
// it as a Bluetooth Xbox Series X.
//
// Y-axis: SDL's MFI code multiplies GCController.yAxis.value by -32767 to
// convert GCController convention (+1=up) to SDL joystick convention (-=up).
// Apple's virtual-device HID layer maps our raw Y axis directly (high value →
// +1 in GCController) without the extra inversion it applies to real BLE
// hardware. We do NOT invert Y; we send high values for physical up.
//
// Report 0x01 (16 bytes including ID):
//   0:     Report ID (0x01)
//   1..2:  LX low/high (UInt16 LE, 0..65535)
//   3..4:  LY  — high = stick up (game convention; MFI inverts for SDL)
//   5..6:  RX
//   7..8:  RY  — same convention as LY
//   9..10: LT, 10-bit LE in bits 0..9; bits 10..15 padding
//   11..12: RT, 10-bit LE in bits 0..9; bits 10..15 padding
//   13:    low nibble hat (1=N, 2=NE, ... 8=NW, 0=neutral), high nibble padding
//   14:    A=0, B=1, X=2, Y=3, LB=4, RB=5, View=6, Menu=7
//   15:    L3=0, R3=1, bits 2..7 padding
struct XboxSeriesOutput: HIDOutputProfile {
    let vendorID: UInt16 = 0x045E
    let productID: UInt16 = 0x0B13
    let productName = "Xbox Wireless Controller"
    let manufacturer: String? = "Microsoft"
    let versionNumber: UInt16 = 0x050F

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

        // Raw vendor input for SDL's GIP code path (report ID 0x20 = GIP_CMD_INPUT).
        // SDL HIDAPI Xbox uses the GIP path when transport != BLE; this report carries
        // the GIP-framed state so SDL can parse it as a standard Xbox input packet.
        0x85, 0x20,       // Report ID (0x20)
        0x06, 0x00, 0xFF, // Usage Page (Vendor 0xFF00)
        0x09, 0x20,       // Usage (0x20)
        0x75, 0x08,       // Report Size (8)
        0x95, 0x12,       // Report Count (18) = opts(1)+seq(1)+len(1)+state(15)
        0x81, 0x02,       // Input (Data, Var, Abs)

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
        let ly = axis16(state.leftStick.y)
        let rx = axis16(state.rightStick.x)
        let ry = axis16(state.rightStick.y)
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

    // SDL HIDAPI Xbox driver uses the GIP code path when transport != BLE. It
    // dispatches on data[0] = GIP command. Report 0x01 arrives as GIP_CMD_ACKNOWLEDGE
    // (ignored). This report uses ID 0x20 = GIP_CMD_INPUT so SDL parses it correctly.
    //
    // GIP input layout (data[] after SDL_hid_read, report ID included as data[0]):
    //   [0]=0x20 cmd  [1]=opts  [2]=seq  [3]=len(15)
    //   [4]=buttons0  [5]=buttons1
    //   [6-7]=LT UInt16LE 0..1023   [8-9]=RT UInt16LE
    //   [10-11]=LX Sint16LE (center=0, right=+)
    //   [12-13]=LY Sint16LE (center=0, down=+; SDL inverts with ~ → negative=up)
    //   [14-15]=RX  [16-17]=RY  [18]=share(0)
    //
    // Y convention: SDL_hidapi_xboxone.c applies `~axis` to Y (invert). To get
    // the correct direction after that inversion, we send down=positive in the
    // GIP report (opposite of our internal positive=up convention).
    //
    // Share byte at state[14]: SDL reads this for Xbox Series X (has_share_button).
    // Our state is 15 bytes so [14] is in-bounds and zeroed (share button off).
    func buildSecondaryReports(_ state: ControllerState, source: any ControllerProfile) -> [Data] {
        let s = state.buttons
        let sh = source.standardShoulders(state)
        var bytes = [UInt8](repeating: 0, count: 19)
        bytes[0] = 0x20  // report ID = GIP_CMD_INPUT
        bytes[1] = 0x00  // opts
        bytes[2] = 0x00  // sequence
        bytes[3] = 0x0F  // payload length (15)

        var b0: UInt8 = 0
        if s.contains(.start) || s.contains(.plus)    { b0 |= 0x04 }  // Menu
        if s.contains(.minus) { b0 |= 0x08 }  // View
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
        if sh.leftBumper           { b1 |= 0x10 }
        if sh.rightBumper          { b1 |= 0x20 }
        if s.contains(.stickL)    { b1 |= 0x40 }
        if s.contains(.stickR)    { b1 |= 0x80 }
        bytes[5] = b1

        let lt = UInt16(UInt32(sh.leftTriggerAnalog) * 1023 / 255)
        let rt = UInt16(UInt32(sh.rightTriggerAnalog) * 1023 / 255)
        bytes[6] = UInt8(lt & 0xFF); bytes[7] = UInt8(lt >> 8)
        bytes[8] = UInt8(rt & 0xFF); bytes[9] = UInt8(rt >> 8)

        // Sint16 LE centered at 0. SDL's HandleStatePacket applies `~axis` to Y
        // axes, so we negate Y here: physical up (internal +) → GIP negative →
        // after ~ → positive... wait the SDL path is: we send down=+, SDL does
        // ~(+) = negative which it treats as "up". Send positive=down for Y.
        func gipAxis(_ value: Int) -> UInt16 {
            UInt16(bitPattern: Int16(clamping: value >= 0 ? value * 258 : value * 256))
        }
        let lx = gipAxis(Int(state.leftStick.x))
        let ly = gipAxis(-Int(state.leftStick.y))   // negate: send down=+ so SDL ~ gives up=-
        let rx = gipAxis(Int(state.rightStick.x))
        let ry = gipAxis(-Int(state.rightStick.y))
        bytes[10] = UInt8(lx & 0xFF); bytes[11] = UInt8(lx >> 8)
        bytes[12] = UInt8(ly & 0xFF); bytes[13] = UInt8(ly >> 8)
        bytes[14] = UInt8(rx & 0xFF); bytes[15] = UInt8(rx >> 8)
        bytes[16] = UInt8(ry & 0xFF); bytes[17] = UInt8(ry >> 8)
        if s.contains(.capture) { bytes[18] |= 0x01 }  // Share
        return [Data(bytes)]
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
