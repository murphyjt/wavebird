@preconcurrency import CoreBluetooth
import Foundation

struct GameCubeProfile: ControllerProfile {
    let name = "Nintendo GameCube Controller"

    private static let features: NS2Feature = [.buttons, .analog, .imu, .rumble]

    // Cmd 0x02/0x04 — read 2 bytes from flash 0x13140: left/right trigger rest position.
    // GC-only: the analog trigger calibration record. Address from SDL
    // (libsdl-org/SDL: src/joystick/hidapi/SDL_hidapi_switch2.c).
    static let triggerCalibrationReadCommand = Data([
        0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00,
        0x02, 0x7E, 0x00, 0x00, 0x40, 0x31, 0x01, 0x00,
    ])

    // Input: the 2-byte flash slice read from 0x13140 (response with ACK + read-info stripped).
    //   [0] left trigger rest position, [1] right trigger rest position
    // Layout from SDL (libsdl-org/SDL: src/joystick/hidapi/SDL_hidapi_switch2.c).
    static func parseTriggerZeros(_ flashData: Data) -> TriggerZeros? {
        guard flashData.count >= 2 else { return nil }
        let b = flashData.startIndex
        return TriggerZeros(left: flashData[b], right: flashData[b + 1])
    }

    func handleCommandResponse(request: Data, response: Data) -> ControllerMetadata? {
        if request.first == 0x02,
           NS2Responses.flashReadAddress(of: request) == 0x13140,
           let zeros = Self.parseTriggerZeros(response.dropFirst(16)) {
            return ControllerMetadata(triggerZeros: zeros)
        }
        return NS2Responses.parseStandard(request: request, response: response)
    }

    var bleMatcher: BLEMatcher? {
        let responseHandles = [NS2Handle.commandResponse1, NS2Handle.commandResponse2]
        let responseChannels: [ResponseChannel] = responseHandles.compactMap { h in
            NS2Handle.uuid(h, for: .gameCube).map { ResponseChannel(uuid: $0, handle: h) }
        }
        return BLEMatcher(
            productID: 0x2073,
            serviceUUID: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0"),
            inputCharacteristic: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2"),
            outputCharacteristic: NS2Handle.uuid(NS2Handle.commandWriteShared, for: .gameCube),
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
                Self.triggerCalibrationReadCommand,
                NS2Commands.sendVibrationData,
                NS2Commands.enableFeatures(Self.features),
            ],
            vibrationCharacteristic: NS2Handle.uuid(0x0012, for: .gameCube)
        )
    }

    var usbMatcher: USBMatcher? { nil }

    let hidVendorID: UInt16 = 0x057E
    let hidProductID: UInt16 = 0x2073

    var vendorPassthroughDescriptor: Data { VirtualHIDDevice.ns2VendorDescriptor(reportID: 0x05, byteCount: 63) }

    // NS2 GC Output Report 0x03 (42 bytes, BLE handle 0x0012):
    //   byte[0]  = 0x00 (Report ID for BT)
    //   byte[1]  = 0x50 | tid (state byte: enable=1, ops_cnt=1, tid in low nibble)
    //   byte[2]  = 0x01 (motor on) or 0x00 (motor off)
    //   bytes[3..41] = reserved zeros
    //
    // GC has a single on/off motor with no amplitude axis, so any non-zero
    // amplitude on either side turns it on. The tid nibble must vary across
    // successive sends or the controller dedupes them; the coordinator
    // supplies the sequence counter for that.
    func encodeRumble(_ cmd: RumbleCommand, sequence: UInt8, settings: RumbleSettings.Snapshot) -> Data? {
        // Intensity-off suppresses non-stop sends entirely (saves BLE). Stop
        // commands still go through so any in-flight rumble can be quieted.
        if settings.intensity == 0 && !cmd.isStop { return nil }
        var packet = Data(count: 42)
        packet[0] = 0x00
        packet[1] = 0x50 | (sequence & 0xF)
        packet[2] = cmd.isStop ? 0x00 : 0x01
        return packet
    }

    func parseBLEReport(_ data: Data, calibration: ControllerCalibration) -> ControllerState? {
        NS2Report0x05.decode(data).map { decode($0, calibration: calibration) }
    }

    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: ControllerCalibration) -> ControllerState? {
        guard reportID == 0x05 else { return nil }
        return NS2Report0x05.decode(data).map { decode($0, calibration: calibration) }
    }

    private func decode(_ d: NS2Report0x05.Decoded, calibration: ControllerCalibration) -> ControllerState {
        let buttons = NS2ButtonBits.decode(d.buttonBits, table: NS2ButtonBits.gameCube)

        // Apply the per-controller trigger rest position read from flash 0x13140
        // during init, then rescale so a full pull reaches 255. Falls through to
        // the raw byte when calibration hasn't arrived yet.
        let zeros = calibration.triggerZeros
        let triggerL = zeros.map { Self.scaleTrigger(d.rawTriggerL, zero: $0.left)  } ?? d.rawTriggerL
        let triggerR = zeros.map { Self.scaleTrigger(d.rawTriggerR, zero: $0.right) } ?? d.rawTriggerR

        // GC layout: ZL/Z are the top digital shoulders, L/R are the bottom
        // analog triggers (each click-detects at full pull). Tops → bumpers,
        // L/R clicks → trigger-digital, analog from the calibrated reading.
        let shoulders = StandardShoulders(
            leftBumper: buttons.contains(.zl),
            rightBumper: buttons.contains(.z),
            leftTriggerDigital: buttons.contains(.l),
            rightTriggerDigital: buttons.contains(.r),
            leftTriggerAnalog: triggerL,
            rightTriggerAnalog: triggerR
        )

        return ControllerState(
            leftStick:  NS2Sticks.decode(d.leftStickRaw,  calibration.left),
            rightStick: NS2Sticks.decode(d.rightStickRaw, calibration.right),
            triggerL: triggerL,
            triggerR: triggerR,
            buttons: buttons,
            // The GC populates the same report-0x05 motion block the Pro does —
            // verified on hardware 2026-08-31: 99% of reports carry non-zero
            // samples, ~4096/g at rest, gyro swinging to +/-3000 when rotated.
            // It was previously requested via the feature mask and discarded.
            //
            // The axis remap is VERIFIED for this shell too, 2026-08-31. The
            // shared parseIMU applies geometry derived for the Pro Controller,
            // so it was checked against a real NS1 Pro in three orientations
            // (Tools/NS1Dump.swift `imu virtual` here, `imu` there) — gravity
            // lands on the same axis with the same sign in each:
            //             GameCube              real NS1 Pro
            //   flat      (-123, +14, +4133)    (-724, +68, +4092)
            //   left edge (+280, -4100,  -78)   ( +11, -4033, +423)
            //   nose down (-4100, +92, -194)    (-4048, +152, -404)
            // Judge this at the wire level only; GCMotion applies its own
            // undocumented remap and makes a correct frame look rotated.
            //
            // The flat X term differs (-123 vs -724) because the GC shell rests
            // ~1.7 deg off vertical where a Pro rests ~10 deg. That also means
            // the 6-Axis Horizontal Offsets we serve at SPI 0x6080 are the Pro
            // Controller's and are wrong for this shell by ~8 deg — harmless
            // only for as long as nothing is shown to consume that block.
            imu: NS2Report0x05.parseIMU(d.imuSlice),
            timestamp: .now,
            shoulders: shoulders
        )
    }

    // Map a raw GC trigger byte onto 0...255.
    //
    // Subtracting the rest position alone is not enough: a full pull reads
    // about 232, NOT 255, so the result topped out near (232 - zero) and the
    // last ~20% of travel was unreachable. Both the rest offset and the 232
    // full-scale constant come from SDL's MapTriggerAxis
    // (SDL_hidapi_switch2.c), which computes
    // clamp((value - zero) / (232 - zero), 0, 1). See README Credits.
    static func scaleTrigger(_ raw: UInt8, zero: UInt8) -> UInt8 {
        let span = Int(Self.triggerFullScale) - Int(zero)
        guard span > 0 else { return raw }
        let scaled = (Int(raw) - Int(zero)) * 255 / span
        return UInt8(clamping: scaled)
    }

    // Raw value at full pull, from SDL. Not 255 — the hardware tops out here.
    static let triggerFullScale: UInt8 = 232
}
