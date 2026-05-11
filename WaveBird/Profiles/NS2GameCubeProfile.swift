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

    static let firmwareInfoCommand = Data([
        0x10, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
    ])

    // Response: 8-byte ACK header + payload at offset 8.
    //   [8..10] controller fw major.minor.micro
    //   [11]    controller type (0x03 = GameCube)
    //   [12..14] Bluetooth patch major.minor.micro
    static func parseFirmwareInfo(_ data: Data) -> FirmwareInfo? {
        guard data.count >= 15 else { return nil }
        let b = data.startIndex
        return FirmwareInfo(
            controllerVersion: (data[b + 8], data[b + 9], data[b + 10]),
            controllerType: data[b + 11],
            bluetoothPatch: (data[b + 12], data[b + 13], data[b + 14])
        )
    }

    var bleMatcher: BLEMatcher? {
        BLEMatcher(
            productID: 0x2073,
            serviceUUID: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0"),
            inputCharacteristic: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2"),
            outputCharacteristic: CBUUID(string: "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005"),
            responseCharacteristic: CBUUID(string: "C765A961-D9D8-4D36-A20A-5315B111836A"),
            initCommands: [
                // Play vibration sample 0x03 "connection" (cmd 0x0A, subcmd 0x02).
                Data([
                    0x0A, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00,
                    0x03, 0x00, 0x00, 0x00,
                ]),
                // Player 1 LED via setLEDPattern (cmd 0x09, subcmd 0x07).
                Data([
                    0x09, 0x91, 0x01, 0x07, 0x00, 0x08, 0x00, 0x00,
                    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ]),
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
