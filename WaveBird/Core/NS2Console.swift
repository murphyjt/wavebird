@preconcurrency import CoreBluetooth
import Foundation

// Console-channel fallback for third-party Joy-Con 2 implementations.
// Protocol references (facts only; implementation is original):
// ndeadly/switch2_controller_research/bluetooth_interface.md and
// JoeGeC/joycon2android/docs/protocol.md, NYXI Hyperion 3 measurements.
struct BLEConsoleFallback: Sendable {
    let serviceUUID = CBUUID(string: "00C5AF5D-1964-4E30-8F51-1956F96BD280")
    let sessionStart = CBUUID(string: "00C5AF5D-1964-4E30-8F51-1956F96BD282")
    let rateDescriptor = CBUUID(string: "679D5510-5A24-4DEE-9557-95DF80486ECB")
    let inputCharacteristic: CBUUID
    let inputReportID: UInt8
}

enum NS2Console {
    private static func frame(_ command: UInt8, _ subcommand: UInt8, _ payload: [UInt8] = [], transport: UInt8 = 1) -> Data {
        Data([command, 0x91, transport, subcommand, 0, UInt8(payload.count), 0, 0] + payload)
    }
    private static func read(_ address: UInt32, _ length: UInt8) -> Data {
        frame(2, 4, [length, 0x7e, 0, 0, UInt8(address & 255), UInt8((address >> 8) & 255), UInt8((address >> 16) & 255), UInt8(address >> 24)], transport: 0)
    }
    // Volatile connection setup plus read-only factory/calibration queries.
    // Deliberately excludes pairing (0x15), flash writes and firmware update.
    static let commands: [Data] = [
        frame(7, 1), read(0x13000, 64), frame(0x10, 1), frame(0x16, 1),
        frame(0x0a, 2, [3, 0, 0, 0]), frame(9, 7, [1, 0, 0, 0, 0, 0, 0, 0]),
        frame(0x0c, 2, [0x37, 0, 0, 0]), read(0x13080, 64),
        read(0x1fc040, 64), read(0x13040, 16), read(0x13100, 24),
        frame(0x11, 3), read(0x13060, 32), frame(0x11, 1),
    ]
}

enum NS2ConsoleReport {
    static func decode(_ data: Data, left: Bool, calibration: ControllerCalibration) -> ControllerState? {
        guard data.count == 63 else { return nil }
        let p = Array(data)
        guard p[4] == 7 else { return nil }
        let keyMap: [ButtonSet] = left
            ? [.dpadDown, .dpadRight, .dpadLeft, .dpadUp, .l, .zl, .minus, .stickL]
            : [.b, .a, .y, .x, .r, .zr, .plus, .stickR]
        var buttons: ButtonSet = []
        for i in 0..<8 where p[2] & (1 << i) != 0 { buttons.formUnion(keyMap[i]) }
        if p[3] & 1 != 0 { buttons.formUnion(left ? .capture : .home) }
        if !left, p[3] & 0x10 != 0 { buttons.insert(.c) }
        if p[3] & 0x40 != 0 { buttons.insert(.sr) }
        if p[3] & 0x80 != 0 { buttons.insert(.sl) }
        let raw = (UInt16(p[5]) | UInt16(p[6] & 15) << 8, UInt16(p[6] >> 4) | UInt16(p[7]) << 4)
        let stick = NS2Sticks.decode(raw, left ? calibration.left : calibration.right)
        // Do not invent gyro samples from the NYXI's accelerometer-only block.
        return ControllerState(leftStick: left ? stick : .zero, rightStick: left ? .zero : stick,
            triggerL: 0, triggerR: 0, buttons: buttons, imu: nil, timestamp: .now,
            shoulders: StandardShoulders(leftBumper: buttons.contains(.l), rightBumper: buttons.contains(.r),
                leftTriggerDigital: buttons.contains(.zl), rightTriggerDigital: buttons.contains(.zr),
                leftTriggerAnalog: buttons.contains(.zl) ? 255 : 0, rightTriggerAnalog: buttons.contains(.zr) ? 255 : 0))
    }
}
