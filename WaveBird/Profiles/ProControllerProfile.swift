@preconcurrency import CoreBluetooth
import Foundation

struct ProControllerProfile: ControllerProfile {
    let name = "Pro Controller"

    private static let features: NS2Feature = [.buttons, .analog, .imu, .unknown3, .rumble]

    var bleMatcher: BLEMatcher? {
        let responseHandles = [NS2Handle.commandResponse1, NS2Handle.commandResponse2]
        let responseChannels: [ResponseChannel] = responseHandles.compactMap { h in
            NS2Handle.uuid(h, for: .pro).map { ResponseChannel(uuid: $0, handle: h) }
        }
        return BLEMatcher(
            productID: 0x2069,
            serviceUUID: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0"),
            // Subscribe to shared Report 0x05 (handle 0x000A). Report 0x09 carries the same
            // sticks/buttons plus battery + motion via the per-controller input handle, but
            // 0x05 is sufficient for what we currently expose through CoreHID.
            inputCharacteristic: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2"),
            outputCharacteristic: NS2Handle.uuid(NS2Handle.commandWriteShared, for: .pro),
            responseCharacteristics: responseChannels,
            initCommands: [
                NS2Commands.handshake,
                NS2Commands.factoryDataRead,
                NS2Commands.leftStickCalibrationRead,
                NS2Commands.rightStickCalibrationRead,
                NS2Commands.firmwareInfo,
                NS2Commands.pairingInfoRead,
                NS2Commands.connectionVibration,
                NS2Commands.player1LED,
                NS2Commands.setFeatureMask(Self.features),
                NS2Commands.sendVibrationData,
                NS2Commands.enableFeatures(Self.features),
            ],
            vibrationCharacteristic: CBUUID(string: "CC483F51-9258-427D-A939-630C31F72B05")
        )
    }

    var usbMatcher: USBMatcher? { nil }

    let hidVendorID: UInt16 = 0x057E
    let hidProductID: UInt16 = 0x2069

    var hidDescriptor: Data { VirtualHIDDevice.standardGamepadDescriptor }
    var vendorPassthroughDescriptor: Data { VirtualHIDDevice.ns2VendorDescriptor(reportID: 0x05, byteCount: 63) }

    // Per darthcloud's BR issue #1249: the Switch 2 console sends an output report
    // after every input report (~67 Hz on our link). Pro 2 rumble decays / glitches
    // when the source falls below that cadence, so heartbeat every 15 ms regardless
    // of how often the host writes Set Reports.
    var rumbleRefreshInterval: Duration? { .milliseconds(15) }

    // NS2 Pro Output Report 0x02 (42 bytes, BLE handle 0x0012):
    //   byte[0]      = 0x00 (Report ID for BT)
    //   bytes[1..16] = Left  LRA: state byte + 1 op (5 bytes) + padding
    //   bytes[17..32]= Right LRA: state byte + 1 op (5 bytes) + padding
    //   bytes[33..41]= reserved
    //
    // State byte: enable[6] | ops_cnt[5:4] | tid[3:0]. tid is supplied by the coordinator
    // so successive identical commands aren't deduped.
    //
    // Per-op layout (darthcloud's sw2_lra_op_t): 32-bit val with
    //   lf_freq[8:0] | lf_en_tone[9] | lf_amp[19:10] | hf_freq[28:20] | hf_en_tone[29]
    //   | tbd[30] | enable[31]
    // + separate 8-bit hf_amp byte at byte 4. One encoder, one bit layout — the SDL vs
    // BlueRetro choice is just a preset of starting values for the user's per-band sliders.

    func encodeRumble(_ cmd: RumbleCommand, sequence: UInt8, settings: RumbleSettings.Snapshot) -> Data? {
        // Intensity-off suppresses non-stop sends entirely (saves BLE). Stop
        // commands still go through so any in-flight rumble can be quieted.
        if settings.intensity == 0 && !cmd.isStop { return nil }
        let tid = sequence & 0xF
        let ops = encodeLRAOps(cmd: cmd, settings: settings)
        var packet = Data(count: 42)
        packet[0]  = 0x00
        packet[1]  = (ops.leftActive  ? 0x50 : 0x10) | tid
        for i in 0..<5 { packet[2 + i]  = ops.left[i] }
        packet[17] = (ops.rightActive ? 0x50 : 0x10) | tid
        for i in 0..<5 { packet[18 + i] = ops.right[i] }
        return packet
    }

    private func encodeLRAOps(
        cmd: RumbleCommand, settings: RumbleSettings.Snapshot
    ) -> (left: [UInt8], leftActive: Bool, right: [UInt8], rightActive: Bool) {
        let leftAmp  = UInt16(Double(cmd.leftAmp)  * settings.intensity)
        let rightAmp = UInt16(Double(cmd.rightAmp) * settings.intensity)

        // Per-side carriers: command overrides (test patterns) win, otherwise settings
        // supply both HF and LF freqs. clampFreq guards against override values outside
        // the 9-bit field's safe range.
        let leftHf  = RumbleSettings.clampFreq(cmd.leftFreqOverride  ?? settings.leftHiFreq)
        let rightHf = RumbleSettings.clampFreq(cmd.rightFreqOverride ?? settings.rightHiFreq)
        let leftLf  = RumbleSettings.clampFreq(cmd.leftFreqOverride  ?? settings.leftLoFreq)
        let rightLf = RumbleSettings.clampFreq(cmd.rightFreqOverride ?? settings.rightLoFreq)

        // Per-band amp = cmd_amp × user scale × field max / 0xFFFF.
        // hf_amp byte saturates at 255; lf_amp 10-bit field saturates at 1023.
        let leftHfAmp  = scaledByte(amp: leftAmp,  scale: settings.leftHiAmpScale)
        let leftLfAmp  = scaledTen( amp: leftAmp,  scale: settings.leftLoAmpScale)
        let rightHfAmp = scaledByte(amp: rightAmp, scale: settings.rightHiAmpScale)
        let rightLfAmp = scaledTen( amp: rightAmp, scale: settings.rightLoAmpScale)

        return (
            left:        packLRAOp(hfFreq: leftHf,  hfAmp: leftHfAmp,  lfFreq: leftLf,  lfAmp: leftLfAmp,  enable: leftAmp  > 0),
            leftActive:  leftAmp  > 0,
            right:       packLRAOp(hfFreq: rightHf, hfAmp: rightHfAmp, lfFreq: rightLf, lfAmp: rightLfAmp, enable: rightAmp > 0),
            rightActive: rightAmp > 0
        )
    }

    private func scaledByte(amp: UInt16, scale: Double) -> UInt8 {
        let v = Double(amp) * scale * 255.0 / Double(UInt16.max)
        return UInt8(min(max(v, 0), 255))
    }

    private func scaledTen(amp: UInt16, scale: Double) -> UInt16 {
        let v = Double(amp) * scale * 1023.0 / Double(UInt16.max)
        return UInt16(min(max(v, 0), 1023))
    }

    // BlueRetro sw2_lra_op_t layout. 32-bit val (LE bytes 0..3) with bit-packed
    // {lf_freq, lf_en_tone, lf_amp, hf_freq, hf_en_tone, tbd, enable} + separate 8-bit
    // hf_amp byte at byte 4. en_tone bits and tbd left at 0 — neither has a known
    // effect from the BR research and we don't expose them in the UI yet.
    private func packLRAOp(
        hfFreq: UInt16, hfAmp: UInt8,
        lfFreq: UInt16, lfAmp: UInt16,
        enable: Bool
    ) -> [UInt8] {
        let val: UInt32 =
              (UInt32(lfFreq) & 0x1FF)             // bits  0..8  lf_freq (9b)
            | ((UInt32(lfAmp) & 0x3FF) << 10)      // bits 10..19 lf_amp  (10b)
            | ((UInt32(hfFreq) & 0x1FF) << 20)     // bits 20..28 hf_freq (9b)
            | ((enable ? UInt32(1) : 0) << 31)     // bit  31     enable  (1b)
        return [
            UInt8( val        & 0xFF),
            UInt8((val >>  8) & 0xFF),
            UInt8((val >> 16) & 0xFF),
            UInt8((val >> 24) & 0xFF),
            hfAmp,
        ]
    }

    // Pro descriptor: 4 sticks + 2 triggers + hat + 16 buttons. See VirtualHIDDevice
    // for layout. ZL/ZR are digital on Pro — we drive both the trigger axes (0/0xFF)
    // and dedicated button slots, matching SDL's dual-mapping convention.
    func buildHIDReport(_ state: ControllerState) -> Data {
        let s = state.buttons
        var bytes = [UInt8](repeating: 0, count: 9)
        bytes[0] = UInt8(bitPattern: state.leftStick.x)
        bytes[1] = UInt8(bitPattern: state.leftStick.y)
        bytes[2] = UInt8(bitPattern: state.rightStick.x)
        bytes[3] = UInt8(bitPattern: state.rightStick.y)
        bytes[4] = s.contains(.zl) ? 0xFF : 0x00
        bytes[5] = s.contains(.zr) ? 0xFF : 0x00
        bytes[6] = VirtualHIDDevice.hatValue(
            up: s.contains(.dpadUp),
            right: s.contains(.dpadRight),
            down: s.contains(.dpadDown),
            left: s.contains(.dpadLeft)
        ) & 0x0F

        var b: UInt16 = 0
        if s.contains(.b)       { b |= 1 << 0 }   // 1  — SOUTH
        if s.contains(.a)       { b |= 1 << 1 }   // 2  — EAST
        if s.contains(.y)       { b |= 1 << 2 }   // 3  — WEST
        if s.contains(.x)       { b |= 1 << 3 }   // 4  — NORTH
        if s.contains(.l)       { b |= 1 << 4 }   // 5  — LEFT_SHOULDER
        if s.contains(.r)       { b |= 1 << 5 }   // 6  — RIGHT_SHOULDER
        if s.contains(.zl)      { b |= 1 << 6 }   // 7  — ZL
        if s.contains(.zr)      { b |= 1 << 7 }   // 8  — ZR
        if s.contains(.minus)   { b |= 1 << 8 }   // 9  — BACK / Minus
        if s.contains(.plus)    { b |= 1 << 9 }   // 10 — START / Plus
        if s.contains(.stickL)  { b |= 1 << 10 }  // 11 — LEFT_STICK click
        if s.contains(.stickR)  { b |= 1 << 11 }  // 12 — RIGHT_STICK click
        if s.contains(.home)    { b |= 1 << 12 }  // 13 — GUIDE / Home
        if s.contains(.capture) { b |= 1 << 13 }  // 14 — Capture
        if s.contains(.c)       { b |= 1 << 14 }  // 15 — C
        bytes[7] = UInt8(b & 0xFF)
        bytes[8] = UInt8(b >> 8)
        return Data(bytes)
    }

    func parseBLEReport(_ data: Data, calibration: ControllerCalibration) -> ControllerState? {
        guard data.count >= 62 else { return nil }
        return Self.parse0x05(data, offset: 0, calibration: calibration)
    }

    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: ControllerCalibration) -> ControllerState? {
        guard reportID == 0x05, data.count >= 62 else { return nil }
        return Self.parse0x05(data, offset: 0, calibration: calibration)
    }

    // Shared Report 0x05 layout (hid_reports.md). Pro-specific button semantics: bit 7 is
    // ZR (not Z), bits 8/9 are Minus/Plus (not Start), bits 10/11 are stick clicks.
    static func parse0x05(_ data: Data, offset: Int, calibration: ControllerCalibration) -> ControllerState {
        let base = data.startIndex.advanced(by: offset)
        let (lx, ly) = NS2Sticks.unpack(data, at: base + 10)
        let (rx, ry) = NS2Sticks.unpack(data, at: base + 13)

        let btn = UInt32(data[base + 4])
            | (UInt32(data[base + 5]) << 8)
            | (UInt32(data[base + 6]) << 16)
            | (UInt32(data[base + 7]) << 24)

        var buttons: ButtonSet = []
        if btn & (1 << 0)  != 0 { buttons.insert(.y) }
        if btn & (1 << 1)  != 0 { buttons.insert(.x) }
        if btn & (1 << 2)  != 0 { buttons.insert(.b) }
        if btn & (1 << 3)  != 0 { buttons.insert(.a) }
        if btn & (1 << 6)  != 0 { buttons.insert(.r) }
        if btn & (1 << 7)  != 0 { buttons.insert(.zr) }
        if btn & (1 << 8)  != 0 { buttons.insert(.minus) }
        if btn & (1 << 9)  != 0 { buttons.insert(.plus) }
        if btn & (1 << 10) != 0 { buttons.insert(.stickR) }
        if btn & (1 << 11) != 0 { buttons.insert(.stickL) }
        if btn & (1 << 12) != 0 { buttons.insert(.home) }
        if btn & (1 << 13) != 0 { buttons.insert(.capture) }
        if btn & (1 << 14) != 0 { buttons.insert(.c) }
        if btn & (1 << 16) != 0 { buttons.insert(.dpadDown) }
        if btn & (1 << 17) != 0 { buttons.insert(.dpadUp) }
        if btn & (1 << 18) != 0 { buttons.insert(.dpadRight) }
        if btn & (1 << 19) != 0 { buttons.insert(.dpadLeft) }
        if btn & (1 << 22) != 0 { buttons.insert(.l) }
        if btn & (1 << 23) != 0 { buttons.insert(.zl) }

        // Pro layout: L/R are the top bumpers, ZL/ZR are the bottom digital
        // triggers. Pro has no analog trigger axis, so analog pegs to 0xFF
        // on press.
        let shoulders = StandardShoulders(
            leftBumper: buttons.contains(.l),
            rightBumper: buttons.contains(.r),
            leftTriggerDigital: buttons.contains(.zl),
            rightTriggerDigital: buttons.contains(.zr),
            leftTriggerAnalog: buttons.contains(.zl) ? 0xFF : 0,
            rightTriggerAnalog: buttons.contains(.zr) ? 0xFF : 0
        )

        return ControllerState(
            leftStick:  SIMD2(NS2Sticks.axis(lx, calibration.left, axis: .x),
                              NS2Sticks.axis(ly, calibration.left, axis: .y, invert: true)),
            rightStick: SIMD2(NS2Sticks.axis(rx, calibration.right, axis: .x),
                              NS2Sticks.axis(ry, calibration.right, axis: .y, invert: true)),
            triggerL: 0,
            triggerR: 0,
            buttons: buttons,
            imu: parseIMU(data, base: base),
            timestamp: .now,
            shoulders: shoulders
        )
    }

    // Motion data: 18 bytes at offset 0x2A — 4B timestamp, 2B temperature,
    // then six Int16 LE (accelX, accelY, accelZ, gyroX, gyroY, gyroZ).
    //
    // Linear-axis swap (accel + gyro X/Y) follows the -90° about Z geometry
    // derived from SDL's switch.c and switch2.c remaps:
    //   NS1.X = +NS2.Y    NS1.Y = -NS2.X    NS1.Z = +NS2.Z
    // Gyro Z (yaw) is additionally negated — empirically Apple's NS1 Pro
    // driver inverts yaw relative to SDL's convention, so we pre-flip the
    // wire byte so it lands right at the host.
    //
    // Accel scale matches NS1 (~4096 LSB/g); gyro scale is within ~15% of
    // NS1's ~40 rad/s full range so we pass through unscaled. Returns nil
    // when the slot is all zeros — IMU disabled or feature bit not yet
    // enabled.
    private static func parseIMU(_ data: Data, base: Data.Index) -> IMUSample? {
        let i = base + 0x2A + 6
        guard data.endIndex - i >= 12 else { return nil }
        let ax = readInt16LE(data, at: i)
        let ay = readInt16LE(data, at: i + 2)
        let az = readInt16LE(data, at: i + 4)
        let gx = readInt16LE(data, at: i + 6)
        let gy = readInt16LE(data, at: i + 8)
        let gz = readInt16LE(data, at: i + 10)
        if ax == 0 && ay == 0 && az == 0 && gx == 0 && gy == 0 && gz == 0 { return nil }
        return IMUSample(
            accelX: ay,
            accelY: negSat(ax),
            accelZ: az,
            gyroX:  gy,
            gyroY:  negSat(gx),
            gyroZ:  negSat(gz)
        )
    }

    private static func readInt16LE(_ data: Data, at i: Data.Index) -> Int16 {
        Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i + 1]) << 8))
    }

    private static func negSat(_ v: Int16) -> Int16 {
        v == .min ? .max : -v
    }
}
