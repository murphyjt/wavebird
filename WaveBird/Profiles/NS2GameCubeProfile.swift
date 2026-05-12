@preconcurrency import CoreBluetooth
import Foundation

struct FirmwareInfo: Sendable, CustomStringConvertible {
    var controllerVersion: (UInt8, UInt8, UInt8)
    var controllerType: UInt8
    var bluetoothPatch: (UInt8, UInt8, UInt8)

    var typeName: String {
        switch controllerType {
        case 0x00: "JoyCon (L)"
        case 0x01: "JoyCon (R)"
        case 0x02: "Pro Controller"
        case 0x03: "GameCube"
        default:   String(format: "0x%02X", controllerType)
        }
    }

    var description: String {
        let (cM, cm, cp) = controllerVersion
        let (bM, bm, bp) = bluetoothPatch
        return "\(typeName) fw \(cM).\(cm).\(cp), BT patch \(bM).\(bm).\(bp)"
    }
}

struct NS2GameCubeProfile: ControllerProfile {
    let name = "Nintendo GameCube Controller"

    // Cmd 0x07/0x01 — "unknown" handshake. Always the first command sent.
    static let handshakeCommand = Data([
        0x07, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
    ])

    // Cmd 0x02/0x04 — read 0x40 bytes from flash 0x13000 (factory block: serial + more).
    static let factoryDataReadCommand = Data([
        0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00,
        0x40, 0x7E, 0x00, 0x00, 0x00, 0x30, 0x01, 0x00,
    ])

    // Cmd 0x02/0x04 — read 2 bytes from flash 0x13140: left/right trigger rest position.
    // Address and parse offsets come from SDL's HIDAPI Switch2 driver
    // (libsdl-org/SDL: src/joystick/hidapi/SDL_hidapi_switch2.c).
    static let triggerCalibrationReadCommand = Data([
        0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00,
        0x02, 0x7E, 0x00, 0x00, 0x40, 0x31, 0x01, 0x00,
    ])

    // Cmd 0x10/0x01 — get firmware version info.
    static let firmwareInfoCommand = Data([
        0x10, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
    ])

    // GC reports buttons | analog | IMU | rumble. Pro adds bit 0x08; JoyCon adds mouse (0x10).
    private static let featureMask: UInt8 = 0x27

    // Cmd 0x0C/0x02 — declare which features are allowed in subsequent enable/disable calls.
    static let setFeatureMaskCommand = Data([
        0x0C, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00,
        featureMask, 0x00, 0x00, 0x00,
    ])

    // Cmd 0x0C/0x04 — turn on the features set in the mask above.
    static let enableFeaturesCommand = Data([
        0x0C, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00,
        featureMask, 0x00, 0x00, 0x00,
    ])

    // Cmd 0x0A/0x08 — "send vibration data". Format not publicly documented; purpose during
    // init is unverified. Both SDL ("Set rumble data?") and BlueRetro send this same payload
    // before turning on the feature mask, so we mirror it.
    static let sendVibrationDataCommand = Data([
        0x0A, 0x91, 0x01, 0x08, 0x00, 0x14, 0x00, 0x00,
        0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0x35, 0x00, 0x46, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])

    // Cmd 0x0A/0x02 — play vibration sample 0x03 ("connection" tone).
    static let connectionVibrationCommand = Data([
        0x0A, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00,
    ])

    // Cmd 0x09/0x07 — set LED bitmask to Player 1.
    static let player1LEDCommand = Data([
        0x09, 0x91, 0x01, 0x07, 0x00, 0x08, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    // Input: the cmd 0x10/0x01 response payload (response with 8-byte ACK header stripped).
    //   [0..2] controller fw major.minor.micro
    //   [3]    controller type (0x03 = GameCube)
    //   [4..6] Bluetooth patch major.minor.micro
    //   [7]    padding; [8..] DSP firmware (Pro only)
    static func parseFirmwareInfo(_ payload: Data) -> FirmwareInfo? {
        guard payload.count >= 7 else { return nil }
        let b = payload.startIndex
        return FirmwareInfo(
            controllerVersion: (payload[b + 0], payload[b + 1], payload[b + 2]),
            controllerType: payload[b + 3],
            bluetoothPatch: (payload[b + 4], payload[b + 5], payload[b + 6])
        )
    }

    // Input: the 0x40-byte flash block read from 0x13000 (response with ACK + read-info stripped).
    //   [0..1] record marker (01 00)
    //   [2..16] 15-byte ASCII serial number
    static func parseSerial(_ flashData: Data) -> String? {
        guard flashData.count >= 17 else { return nil }
        let b = flashData.startIndex
        let field = flashData[(b + 2)..<(b + 17)]
        let printable = field.prefix(while: { (0x20...0x7E).contains($0) })
        guard !printable.isEmpty else { return nil }
        return String(decoding: printable, as: UTF8.self)
    }

    // Input: the 2-byte flash slice read from 0x13140 (response with ACK + read-info stripped).
    //   [0] left trigger rest position, [1] right trigger rest position
    // Layout from SDL (libsdl-org/SDL: src/joystick/hidapi/SDL_hidapi_switch2.c).
    static func parseTriggerZeros(_ flashData: Data) -> (left: UInt8, right: UInt8)? {
        guard flashData.count >= 2 else { return nil }
        let b = flashData.startIndex
        return (flashData[b], flashData[b + 1])
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
                Self.handshakeCommand,
                Self.factoryDataReadCommand,
                Self.firmwareInfoCommand,
                Self.connectionVibrationCommand,
                Self.player1LEDCommand,
                Self.setFeatureMaskCommand,
                Self.triggerCalibrationReadCommand,
                Self.sendVibrationDataCommand,
                Self.enableFeaturesCommand,
            ]
        )
    }

    var usbMatcher: USBMatcher? { nil }

    let hidVendorID: UInt16 = 0x057E
    let hidProductID: UInt16 = 0x2073

    var hidDescriptor: Data { VirtualHIDDevice.placeholderGamepadDescriptor }

    func buildHIDReport(_ state: ControllerState) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = UInt8(bitPattern: state.leftStick.x)
        bytes[1] = UInt8(bitPattern: state.leftStick.y)
        bytes[2] = UInt8(bitPattern: state.rightStick.x)
        bytes[3] = UInt8(bitPattern: state.rightStick.y)
        bytes[4] = state.buttons.contains(.l) ? 127 : state.triggerL >> 1
        bytes[5] = state.buttons.contains(.r) ? 127 : state.triggerR >> 1

        var b: UInt16 = 0
        let s = state.buttons
        if s.contains(.b)         { b |= 1 << 0 }
        if s.contains(.a)         { b |= 1 << 1 }
        if s.contains(.y)         { b |= 1 << 2 }
        if s.contains(.x)         { b |= 1 << 3 }
        if s.contains(.r)         { b |= 1 << 4 }
        if s.contains(.z)         { b |= 1 << 5 }
        if s.contains(.start)     { b |= 1 << 6 }
        if s.contains(.dpadDown)  { b |= 1 << 7 }
        if s.contains(.dpadRight) { b |= 1 << 8 }
        if s.contains(.dpadLeft)  { b |= 1 << 9 }
        if s.contains(.dpadUp)    { b |= 1 << 10 }
        if s.contains(.l)         { b |= 1 << 11 }
        if s.contains(.zl)        { b |= 1 << 12 }
        if s.contains(.home)      { b |= 1 << 13 }
        if s.contains(.capture)   { b |= 1 << 14 }
        if s.contains(.c)         { b |= 1 << 15 }
        bytes[6] = UInt8(b & 0xFF)
        bytes[7] = UInt8(b >> 8)
        return Data(bytes)
    }

    func parseBLEReport(_ data: Data) -> ControllerState? {
        guard data.count >= 62 else { return nil }
        return Self.parse0x05(data, offset: 0)
    }

    func parseUSBReport(_ data: Data, reportID: UInt8) -> ControllerState? {
        guard reportID == 0x05, data.count >= 62 else { return nil }
        return Self.parse0x05(data, offset: 0)
    }

    static func parse0x05(_ data: Data, offset: Int) -> ControllerState {
        let base = data.startIndex.advanced(by: offset)
        let (lx, ly) = stickXY(data, at: base + 10)
        let (rx, ry) = stickXY(data, at: base + 13)

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

        return ControllerState(
            leftStick:  SIMD2(stick8(lx), stick8(ly, invert: true)),
            rightStick: SIMD2(stick8(rx), stick8(ry, invert: true)),
            triggerL: data[base + 60],
            triggerR: data[base + 61],
            buttons: buttons,
            imu: nil,
            timestamp: .now
        )
    }

    static func stickXY(_ data: Data, at i: Int) -> (UInt16, UInt16) {
        let b0 = UInt16(data[i])
        let b1 = UInt16(data[i + 1])
        let b2 = UInt16(data[i + 2])
        return (b0 | ((b1 & 0x0F) << 8), (b1 >> 4) | (b2 << 4))
    }

    static func stick8(_ axis12: UInt16, invert: Bool = false) -> Int8 {
        let v = (Int(axis12) - 2048) >> 3
        let s = invert ? -v : v
        return Int8(clamping: s)
    }
}
