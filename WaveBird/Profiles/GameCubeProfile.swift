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

    var hidDescriptor: Data { VirtualHIDDevice.gcGamepadDescriptor }
    var vendorPassthroughDescriptor: Data { VirtualHIDDevice.ns2VendorDescriptor(reportID: 0x05, byteCount: 63) }

    // GC standard-gamepad report: analog triggers on the trigger axes, d-pad on the hat,
    // full-pull L/R clicks live in their own button slots so consumers can distinguish
    // analog travel from the click event.
    func buildHIDReport(_ state: ControllerState) -> Data {
        let s = state.buttons
        var bytes = [UInt8](repeating: 0, count: 9)
        bytes[0] = UInt8(bitPattern: state.leftStick.x)
        bytes[1] = UInt8(bitPattern: state.leftStick.y)
        bytes[2] = UInt8(bitPattern: state.rightStick.x)
        bytes[3] = UInt8(bitPattern: state.rightStick.y)
        bytes[4] = state.triggerL
        bytes[5] = state.triggerR
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
        if s.contains(.home)    { b |= 1 << 4 }   // 5  — GUIDE
        if s.contains(.start)   { b |= 1 << 5 }   // 6  — START
        if s.contains(.zl)      { b |= 1 << 6 }   // 7  — LEFT_SHOULDER (ZL)
        if s.contains(.z)       { b |= 1 << 7 }   // 8  — RIGHT_SHOULDER (Z)
        if s.contains(.capture) { b |= 1 << 8 }   // 9  — SHARE
        if s.contains(.c)       { b |= 1 << 9 }   // 10 — C
        if s.contains(.l)       { b |= 1 << 10 }  // 11 — L full-pull click
        if s.contains(.r)       { b |= 1 << 11 }  // 12 — R full-pull click
        bytes[7] = UInt8(b & 0xFF)
        bytes[8] = UInt8(b >> 8)
        return Data([0x01]) + Data(bytes)
    }

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
    func encodeRumble(_ cmd: RumbleCommand, sequence: UInt8) -> Data? {
        var packet = Data(count: 42)
        packet[0] = 0x00
        packet[1] = 0x50 | (sequence & 0xF)
        packet[2] = cmd.isStop ? 0x00 : 0x01
        return packet
    }

    func parseBLEReport(_ data: Data, calibration: ControllerCalibration) -> ControllerState? {
        guard data.count >= 62 else { return nil }
        return Self.parse0x05(data, offset: 0, calibration: calibration)
    }

    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: ControllerCalibration) -> ControllerState? {
        guard reportID == 0x05, data.count >= 62 else { return nil }
        return Self.parse0x05(data, offset: 0, calibration: calibration)
    }

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
        if btn & (1 << 7)  != 0 { buttons.insert(.z) }
        if btn & (1 << 9)  != 0 { buttons.insert(.start) }
        if btn & (1 << 12) != 0 { buttons.insert(.home) }
        if btn & (1 << 13) != 0 { buttons.insert(.capture) }
        if btn & (1 << 14) != 0 { buttons.insert(.c) }
        if btn & (1 << 16) != 0 { buttons.insert(.dpadDown) }
        if btn & (1 << 17) != 0 { buttons.insert(.dpadUp) }
        if btn & (1 << 18) != 0 { buttons.insert(.dpadRight) }
        if btn & (1 << 19) != 0 { buttons.insert(.dpadLeft) }
        if btn & (1 << 22) != 0 { buttons.insert(.l) }
        if btn & (1 << 23) != 0 { buttons.insert(.zl) }

        // Apply the per-controller trigger rest position read from flash 0x13140
        // during init: subtract so a released trigger reads 0. Falls through to
        // the raw byte when calibration hasn't arrived yet.
        let zeros = calibration.triggerZeros
        let rawTriggerL = data[base + 60]
        let rawTriggerR = data[base + 61]
        let triggerL = zeros.map { rawTriggerL >= $0.left  ? rawTriggerL - $0.left  : 0 } ?? rawTriggerL
        let triggerR = zeros.map { rawTriggerR >= $0.right ? rawTriggerR - $0.right : 0 } ?? rawTriggerR
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
            leftStick:  SIMD2(NS2Sticks.axis(lx, calibration.left, axis: .x),
                              NS2Sticks.axis(ly, calibration.left, axis: .y, invert: true)),
            rightStick: SIMD2(NS2Sticks.axis(rx, calibration.right, axis: .x),
                              NS2Sticks.axis(ry, calibration.right, axis: .y, invert: true)),
            triggerL: triggerL,
            triggerR: triggerR,
            buttons: buttons,
            imu: nil,
            timestamp: .now,
            shoulders: shoulders
        )
    }
}
