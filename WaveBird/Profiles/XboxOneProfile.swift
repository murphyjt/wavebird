import Foundation

// Xbox One / Xbox One S / Elite controllers over wired USB (GIP).
//
// The physical pad speaks GIP (Game Input Protocol) on a vendor-specific USB
// interface (0xFF/0x47/0xD0) with interrupt IN/OUT pipes — macOS has no
// driver for it, which is exactly why a wired Xbox One pad is a paperweight
// on a Mac. This profile is the *input* side of the WaveBird trick: it parses
// GIP input reports into the canonical ControllerState, and GIP 0x09 rumble
// out of RumbleCommand. The *output* side is the stock `xboxSeries` profile:
// WaveBird already publishes an "Xbox Wireless Controller" (VID 0x045E /
// PID 0x0B13) via CoreHID, so macOS sees the same native GCController it
// would for a Bluetooth Xbox pad.
//
// Integration: the XboxUSBTransport owns the USB plumbing + GIP handshake
// (announce → identify → power-on), and emits each GIP input payload as
// .reportReceived(reportID: nil, data). parseUSBReport below is the profile's
// half of that contract (reportID 0 → real input; 0x07 → synthetic Guide
// edge, see transport).
struct XboxOneProfile: ControllerProfile {
    let name = "Xbox One Controller (USB)"

    var bleMatcher: BLEMatcher? { nil }

    // USB-only profile: no BLE transport to parse. The protocol requires the
    // member (no default exists); always nil.
    func parseBLEReport(_ data: Data, calibration: ControllerCalibration) -> ControllerState? { nil }

    var usbMatcher: USBMatcher? {
        // Interface-matched: empty vendor/product lists accept any device the
        // transport saw expose the GIP vendor interface (the identify
        // handshake confirms it's a gamepad). This covers Microsoft pads and
        // every Xbox-licensed third-party pad (GameSir, PowerA, 8BitDo, …).
        USBMatcher(initWrites: [])
    }

    // Input-side identity (used for placeholder settings keys / UI only; the
    // virtual device identity comes from the output profile's catalog entry).
    let hidVendorID: UInt16 = GIP.vidMicrosoft
    let hidProductID: UInt16 = 0x02D1

    var vendorPassthroughDescriptor: Data { Data() }

    // GIP input arrives at the interrupt endpoint's natural cadence (1537:
    // ~250 Hz — bInterval 4). No re-publish requirement; the session's 80 ms
    // refresh would starve rumble, so require a 10 ms rumble cadence to work
    // around the firmware bug where input stalls after heavy rumble.
    var rumbleRefreshInterval: Duration? { .milliseconds(10) }

    // MARK: parseUSBReport

    // reportID semantics (transport contract):
    //   0x00 (nil) — GIP input payload: 14 bytes (1537/1697) or
    //               14 + 2 (DLI pads) / 14 + 4 (share pads, handled by the
    //               transport via the len−18 / len−26 rule)
    //   0x07      — synthetic Guide state (bit 0x01 in byte 0), merged onto the
    //               last input by the transport; reported as .home below.
    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: ControllerCalibration) -> ControllerState? {
        if reportID == 0x07 {
            // Guide edge (virtual-key command). The transport synthesizes
            // this only when it has seen an input
            // report, and state has no other way to carry Guide over the USB
            // wire — the 1537's input packet has no Guide bit.
            guard data.count >= 1 else { return nil }
            var state = ControllerState.zero
            if data[0] & 0x01 != 0 { state.buttons.insert(.home) }
            return state
        }
        guard let input = GIPGamepadInput.parse(data) else { return nil }

        var state = ControllerState.zero
        var buttons = ButtonSet()

        // Bit positions in the le16 buttons word.
        if input.buttons & (1 << 2) != 0 { buttons.insert(.start) }   // MENU
        if input.buttons & (1 << 3) != 0 { buttons.insert(.minus) }   // VIEW
        // Canonical ButtonSet is position-based (.a=east .b=south .x=north
        // .y=west — see NS2ButtonBits.pro, the output-mode catalogs and every
        // other parser). The Xbox diamond is Xbox-positioned, so its buttons
        // parse to the canonicals for their POSITION: physical A (south) →
        // .b, B (east) → .a, X (west) → .y, Y (north) → .x.
        if input.buttons & (1 << 4) != 0 { buttons.insert(.b) }       // A (south)
        if input.buttons & (1 << 5) != 0 { buttons.insert(.a) }       // B (east)
        if input.buttons & (1 << 6) != 0 { buttons.insert(.y) }       // X (west)
        if input.buttons & (1 << 7) != 0 { buttons.insert(.x) }       // Y (north)
        if input.buttons & (1 << 8) != 0  { buttons.insert(.dpadUp) }
        if input.buttons & (1 << 9) != 0  { buttons.insert(.dpadDown) }
        if input.buttons & (1 << 10) != 0 { buttons.insert(.dpadLeft) }
        if input.buttons & (1 << 11) != 0 { buttons.insert(.dpadRight) }
        if input.buttons & (1 << 12) != 0 { buttons.insert(.l) }      // BUMPER_L
        if input.buttons & (1 << 13) != 0 { buttons.insert(.r) }      // BUMPER_R
        if input.buttons & (1 << 14) != 0 { buttons.insert(.stickL) } // L3
        if input.buttons & (1 << 15) != 0 { buttons.insert(.stickR) } // R3

        // Guide + Share ride the two reserved low bits of the buttons word
        // (the button bits start at 1<<2); the transport latches them from
        // the real wire events (virtual-key for Guide; the end-of-packet
        // Share byte on pads that advertise the share GUID).
        if input.buttons & 0x0001 != 0 { buttons.insert(.home) }
        if input.buttons & 0x0002 != 0 { buttons.insert(.capture) }
        state.buttons = buttons

        // Sticks: s16, center 0; GIP Y is positive-up (and our
        // ControllerState is positive-up natively).
        state.leftStick  = Self.toCentered12(x: input.stickLeftX,  y: input.stickLeftY)
        state.rightStick = Self.toCentered12(x: input.stickRightX, y: input.stickRightY)

        // Triggers: 10-bit (0..1023) → UInt8 (0..255).
        let tl = UInt8(min(255, input.triggerLeft >> 2))
        let tr = UInt8(min(255, input.triggerRight >> 2))
        state.triggerL = tl
        state.triggerR = tr

        // Normalized shoulders so output presentations (Xbox / DS4 / DS /
        // Switch Pro) map bumpers + analog triggers correctly.
        state.shoulders = StandardShoulders(
            leftBumper: input.buttons & (1 << 12) != 0,
            rightBumper: input.buttons & (1 << 13) != 0,
            leftTriggerDigital: tl > 0x08,
            rightTriggerDigital: tr > 0x08,
            leftTriggerAnalog: tl,
            rightTriggerAnalog: tr
        )

        return state
    }

    // 16-bit GIP axes (−32768…32767) → centered 12-bit (−2047…2047), the
    // canonical ControllerState range. Clamps at the rails so a full-swing
    // 32767 doesn't wrap (32767 · 2047 / 32767 = 2047 exactly).
    static func toCentered12(x: Int16, y: Int16) -> SIMD2<Int16> {
        func map(_ v: Int16) -> Int16 {
            Int16(clamping: (Int(v) * 2047) / 32767)
        }
        return SIMD2(map(x), map(y))
    }

    // MARK: encodeRumble

    // RumbleCommand → GIP 0x09 payload via GIPRumble. Main motors + trigger
    // motors (GameSir / Series impulse triggers) ride their own fields.
    // Intensity scales everything like the Pro profile.
    func encodeRumble(_ cmd: RumbleCommand, sequence: UInt8, settings: RumbleSettings.Snapshot) -> Data? {
        if settings.intensity == 0 && !cmd.isStop { return nil }
        let leftAmp  = UInt16(Double(cmd.leftAmp) * settings.intensity)
        let rightAmp = UInt16(Double(cmd.rightAmp) * settings.intensity)
        let ltAmp    = UInt16(Double(cmd.leftTriggerAmp) * settings.intensity)
        let rtAmp    = UInt16(Double(cmd.rightTriggerAmp) * settings.intensity)
        return GIPRumble.payload(leftAmp: leftAmp, rightAmp: rightAmp,
                                 leftTriggerAmp: ltAmp, rightTriggerAmp: rtAmp)
    }
}
