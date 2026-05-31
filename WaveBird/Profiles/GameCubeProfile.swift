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
        // during init: subtract so a released trigger reads 0. Falls through to
        // the raw byte when calibration hasn't arrived yet.
        let zeros = calibration.triggerZeros
        let triggerL = zeros.map { d.rawTriggerL >= $0.left  ? d.rawTriggerL - $0.left  : 0 } ?? d.rawTriggerL
        let triggerR = zeros.map { d.rawTriggerR >= $0.right ? d.rawTriggerR - $0.right : 0 } ?? d.rawTriggerR

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
            imu: nil,
            timestamp: .now,
            shoulders: shoulders
        )
    }
}
