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
        // Pro's per-controller input handle (0x000E) delivers Report 0x09 —
        // the same sticks/buttons as Report 0x05 plus battery + motion. The
        // state-translation path only consumes 0x05 (parseBLEReport), but
        // ns2Passthrough also forwards 0x09 verbatim so the host sees the
        // descriptor's structured button/axis report.
        let secondaryInputs: [InputChannel] = NS2Handle.uuid(NS2Handle.inputReportVariant, for: .pro)
            .map { [InputChannel(uuid: $0, reportID: 0x09)] } ?? []
        return BLEMatcher(
            productID: 0x2069,
            serviceUUID: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0"),
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
            vibrationCharacteristic: CBUUID(string: "CC483F51-9258-427D-A939-630C31F72B05"),
            secondaryInputs: secondaryInputs
        )
    }

    var usbMatcher: USBMatcher? { nil }

    let hidVendorID: UInt16 = 0x057E
    let hidProductID: UInt16 = 0x2069

    // Verbatim from the physical Switch 2 Pro Controller over USB (extracted via
    // ioreg with the device plugged in). Two input reports + one output:
    //   Report 5  (in,  63 vendor bytes)               — subcommand / handshake replies
    //   Report 9  (in,  2 vendor + 21 btn + 4×12b axes + 52 vendor = 63 bytes) — state
    //   Report 2  (out, 63 vendor bytes)               — host writes (rumble / subcommands)
    // Used by ns2Passthrough mode so apps that key off the Switch 2 Pro USB
    // descriptor see the same shape over BLE.
    var vendorPassthroughDescriptor: Data { Self.usbPassthroughDescriptor }

    private static let usbPassthroughDescriptor: Data = Data([
        0x05, 0x01,                       // Usage Page (Generic Desktop)
        0x09, 0x05,                       // Usage (Game Pad)
        0xA1, 0x01,                       // Collection (Application)
        0x85, 0x05,                       //   Report ID (5)
        0x05, 0xFF,                       //   Usage Page (Vendor 0xFF)
        0x09, 0x01,                       //   Usage (0x01)
        0x15, 0x00,                       //   Logical Minimum (0)
        0x26, 0xFF, 0x00,                 //   Logical Maximum (255)
        0x95, 0x3F,                       //   Report Count (63)
        0x75, 0x08,                       //   Report Size (8)
        0x81, 0x02,                       //   Input (Data,Var,Abs)
        0x85, 0x09,                       //   Report ID (9)
        0x09, 0x01,                       //   Usage (0x01) — vendor page still active
        0x95, 0x02,                       //   Report Count (2)
        0x81, 0x02,                       //   Input (2 vendor header bytes)
        0x05, 0x09,                       //   Usage Page (Button)
        0x19, 0x01,                       //   Usage Minimum (1)
        0x29, 0x15,                       //   Usage Maximum (21)
        0x25, 0x01,                       //   Logical Maximum (1)
        0x95, 0x15,                       //   Report Count (21)
        0x75, 0x01,                       //   Report Size (1)
        0x81, 0x02,                       //   Input (21 buttons)
        0x95, 0x01,                       //   Report Count (1)
        0x75, 0x03,                       //   Report Size (3)
        0x81, 0x03,                       //   Input (Const) — 3-bit pad
        0x05, 0x01,                       //   Usage Page (Generic Desktop)
        0x09, 0x01,                       //   Usage (Pointer)
        0xA1, 0x00,                       //   Collection (Physical)
        0x09, 0x30,                       //     Usage (X)
        0x09, 0x31,                       //     Usage (Y)
        0x09, 0x33,                       //     Usage (Rx)
        0x09, 0x35,                       //     Usage (Ry)
        0x26, 0xFF, 0x0F,                 //     Logical Maximum (4095)
        0x95, 0x04,                       //     Report Count (4)
        0x75, 0x0C,                       //     Report Size (12)
        0x81, 0x02,                       //     Input (Data,Var,Abs)
        0xC0,                             //   End Collection
        0x05, 0xFF,                       //   Usage Page (Vendor 0xFF)
        0x09, 0x02,                       //   Usage (0x02)
        0x26, 0xFF, 0x00,                 //   Logical Maximum (255)
        0x95, 0x34,                       //   Report Count (52)
        0x75, 0x08,                       //   Report Size (8)
        0x81, 0x02,                       //   Input (52 vendor trailer bytes — IMU/battery)
        0x85, 0x02,                       //   Report ID (2)
        0x09, 0x01,                       //   Usage (0x01) — vendor page still active
        0x95, 0x3F,                       //   Report Count (63)
        0x91, 0x02,                       //   Output (Data,Var,Abs)
        0xC0                              // End Collection
    ])

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

    func parseBLEReport(_ data: Data, calibration: ControllerCalibration) -> ControllerState? {
        NS2Report0x05.decode(data).map { decode($0, calibration: calibration) }
    }

    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: ControllerCalibration) -> ControllerState? {
        guard reportID == 0x05 else { return nil }
        return NS2Report0x05.decode(data).map { decode($0, calibration: calibration) }
    }

    private func decode(_ d: NS2Report0x05.Decoded, calibration: ControllerCalibration) -> ControllerState {
        let buttons = NS2ButtonBits.decode(d.buttonBits, table: NS2ButtonBits.pro)

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
            leftStick:  NS2Sticks.decode(d.leftStickRaw,  calibration.left),
            rightStick: NS2Sticks.decode(d.rightStickRaw, calibration.right),
            triggerL: 0,
            triggerR: 0,
            buttons: buttons,
            imu: Self.parseIMU(d.imuSlice),
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
    private static func parseIMU(_ slice: Data) -> IMUSample? {
        let i = slice.startIndex + 6
        guard slice.endIndex - i >= 12 else { return nil }
        let ax = readInt16LE(slice, at: i)
        let ay = readInt16LE(slice, at: i + 2)
        let az = readInt16LE(slice, at: i + 4)
        let gx = readInt16LE(slice, at: i + 6)
        let gy = readInt16LE(slice, at: i + 8)
        let gz = readInt16LE(slice, at: i + 10)
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
