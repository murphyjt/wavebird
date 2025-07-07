import Foundation

enum Stick {
    static let neutral: UInt8 = 128
}

enum DSUButton {
    static let released: UInt8 = 0
    static let pressed: UInt8 = 255
}

typealias AnalogValue = UInt8

extension AnalogValue {
    static let released: AnalogValue = 0
    static let pressed: AnalogValue = 255
}

enum HomeButton: UInt8 {
    case released = 0
    case pressed = 1
}

enum TouchButton: UInt8 {
    case released = 0
    case pressed = 1
}

enum ConnectionState: UInt8 {
    case disconnected = 0
    case connected = 1
}

typealias Bitmask = UInt8

// TODO: Encapsulate impl from interface
struct DSUControllerData: Payload {
    var count: Int {
        80
    }

    func data(using data: Data) -> Data {
        var data = data
        data.append(slot)
        data.append(state.rawValue)
        data.append(model.rawValue)
        data.append(connectionType.rawValue)
        data.append(contentsOf: macAddress)
        data.append(batteryStatus.rawValue)
        data.append(connected.rawValue)
        withUnsafeBytes(of: packetNumber) {
            data.append(contentsOf: $0)
        }
        data.append(DPadLeftDownRightUpOptionsR3L3Share)
        data.append(buttonYBAXR1L1R2L2)
        data.append(homeButton.rawValue)
        data.append(touchButton.rawValue)
        data.append(leftStickX)
        data.append(leftStickY)
        data.append(rightStickX)
        data.append(rightStickY)
        data.append(analogDpadLeft)
        data.append(analogDpadDown)
        data.append(analogDpadRight)
        data.append(analogDpadUp)
        data.append(analogY)
        data.append(analogB)
        data.append(analogA)
        data.append(analogX)
        data.append(analogR1)
        data.append(analogL1)
        data.append(analogR2)
        data.append(analogL2)
        // TODO: Why are these arrays okay but accel and gyro aren't?
        data.append(contentsOf: firstTouch)
        data.append(contentsOf: secondTouch)
        withUnsafeBytes(of: motionDataTimestamp) {
            data.append(contentsOf: $0)
        }
        accelerometer.withUnsafeBufferPointer { buffer in
            data.append(contentsOf: UnsafeRawBufferPointer(buffer))
        }
        gyroscope.withUnsafeBufferPointer { buffer in
            data.append(contentsOf: UnsafeRawBufferPointer(buffer))
        }
        return data
    }

    var slot: Slot = .zero
    var state: SlotState = .Disconnected
    var model: DeviceModel = .NotApplicable
    var connectionType: ConnectionType = .NotApplicable
    var macAddress: MACAddress = [UInt8](repeating: 0, count: 6)
    var batteryStatus: BatteryStatus = .NotApplicable

    var connected: ConnectionState = .disconnected
    var packetNumber: UInt32 = 0
    var buttonY: AnalogValue {
        get {
            (buttonYBAXR1L1R2L2 & 0b10000000) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogY = 0
                buttonYBAXR1L1R2L2 &= 0b01111111
            } else {
                analogY = newValue
                buttonYBAXR1L1R2L2 |= 0b10000000
            }
        }
    }

    var buttonB: AnalogValue {
        get {
            (buttonYBAXR1L1R2L2 & 0b01000000) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogB = 0
                buttonYBAXR1L1R2L2 &= 0b10111111
            } else {
                analogB = newValue
                buttonYBAXR1L1R2L2 |= 0b01000000
            }
        }
    }

    var buttonA: AnalogValue {
        get {
            (buttonYBAXR1L1R2L2 & 0b00100000) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogA = 0
                buttonYBAXR1L1R2L2 &= 0b11011111
            } else {
                analogA = newValue
                buttonYBAXR1L1R2L2 |= 0b00100000
            }
        }
    }

    var buttonX: AnalogValue {
        get {
            (buttonYBAXR1L1R2L2 & 0b00010000) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogX = 0
                buttonYBAXR1L1R2L2 &= 0b11101111
            } else {
                analogX = newValue
                buttonYBAXR1L1R2L2 |= 0b00010000
            }
        }
    }

    var buttonR1: AnalogValue {
        get {
            (buttonYBAXR1L1R2L2 & 0b00001000) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogR1 = 0
                buttonYBAXR1L1R2L2 &= 0b11110111
            } else {
                analogR1 = newValue
                buttonYBAXR1L1R2L2 |= 0b00001000
            }
        }
    }

    var buttonL1: AnalogValue {
        get {
            (buttonYBAXR1L1R2L2 & 0b00000100) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogL1 = 0
                buttonYBAXR1L1R2L2 &= 0b11111011
            } else {
                analogL1 = newValue
                buttonYBAXR1L1R2L2 |= 0b00000100
            }
        }
    }

    var buttonR2: AnalogValue {
        get {
            (buttonYBAXR1L1R2L2 & 0b00000010) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogR2 = 0
                buttonYBAXR1L1R2L2 &= 0b11111101
            } else {
                analogR2 = newValue
                buttonYBAXR1L1R2L2 |= 0b00000010
            }
        }
    }

    var buttonL2: AnalogValue {
        get {
            (buttonYBAXR1L1R2L2 & 0b00000001) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogL2 = 0
                buttonYBAXR1L1R2L2 &= 0b11111110
            } else {
                analogL2 = newValue
                buttonYBAXR1L1R2L2 |= 0b00000001
            }
        }
    }
    /// Dolphin only recognizes Options, R3, L3 and Share
    private var DPadLeftDownRightUpOptionsR3L3Share: Bitmask = 0
    /// Dolphin ignores all of there
    private var buttonYBAXR1L1R2L2: Bitmask = 0
    var homeButton: HomeButton = .released
    var touchButton: TouchButton = .released
    var leftStickX: UInt8 = Stick.neutral
    var leftStickY: UInt8 = Stick.neutral
    var rightStickX: UInt8 = Stick.neutral
    var rightStickY: UInt8 = Stick.neutral

    // For Dolphin, these are the values that are used
    var analogDpadLeft: UInt8 = 0
    var analogDpadDown: UInt8 = 0
    var analogDpadRight: UInt8 = 0
    var analogDpadUp: UInt8 = 0
    var analogY: UInt8 = 0
    var analogB: UInt8 = 0
    var analogA: UInt8 = 0
    var analogX: UInt8 = 0
    var analogR1: UInt8 = 0
    var analogL1: UInt8 = 0
    var analogR2: UInt8 = 0
    var analogL2: UInt8 = 0

    // Everything below is unsupported for now
    var firstTouch: [UInt8] = Array(repeating: 0, count: 6)
    var secondTouch: [UInt8] = Array(repeating: 0, count: 6)
    var motionDataTimestamp: UInt64 = 0
    // TODO: These may need to be broken out
    var accelerometer: [Float32] = Array(repeating: 0, count: 3)
    /// X axis, Y axis, Z axis
    var gyroscope: [Float32] = Array(repeating: 0, count: 3)/// Pitch, Yaw, Roll
}

extension DSUControllerData {
    var dpadLeft: AnalogValue {
        get {
            (DPadLeftDownRightUpOptionsR3L3Share & 0b10000000) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogDpadLeft = .released
                DPadLeftDownRightUpOptionsR3L3Share &= 0b01111111
            } else {
                analogDpadLeft = .pressed
                DPadLeftDownRightUpOptionsR3L3Share |= 0b10000000
            }
        }
    }

    var dpadDown: AnalogValue {
        get {
            (DPadLeftDownRightUpOptionsR3L3Share & 0b01000000) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogDpadDown = .released
                DPadLeftDownRightUpOptionsR3L3Share &= 0b10111111
            } else {
                analogDpadDown = .pressed
                DPadLeftDownRightUpOptionsR3L3Share |= 0b01000000
            }
        }
    }

    var dpadRight: AnalogValue {
        get {
            (DPadLeftDownRightUpOptionsR3L3Share & 0b00100000) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogDpadRight = .released
                DPadLeftDownRightUpOptionsR3L3Share &= 0b11011111
            } else {
                analogDpadRight = .pressed
                DPadLeftDownRightUpOptionsR3L3Share |= 0b00100000
            }
        }
    }

    var dpadUp: AnalogValue {
        get {
            (DPadLeftDownRightUpOptionsR3L3Share & 0b00010000) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                analogDpadUp = .released
                DPadLeftDownRightUpOptionsR3L3Share &= 0b11101111
            } else {
                analogDpadUp = .pressed
                DPadLeftDownRightUpOptionsR3L3Share |= 0b00010000
            }
        }
    }

    var options: AnalogValue {
        get {
            (DPadLeftDownRightUpOptionsR3L3Share & 0b00001000) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                DPadLeftDownRightUpOptionsR3L3Share &= 0b11110111
            } else {
                DPadLeftDownRightUpOptionsR3L3Share |= 0b00001000
            }
        }
    }

    var r3: AnalogValue {
        get {
            (DPadLeftDownRightUpOptionsR3L3Share & 0b00000100) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                DPadLeftDownRightUpOptionsR3L3Share &= 0b11111011
            } else {
                DPadLeftDownRightUpOptionsR3L3Share |= 0b00000100
            }
        }
    }

    var l3: AnalogValue {
        get {
            (DPadLeftDownRightUpOptionsR3L3Share & 0b00000010) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                DPadLeftDownRightUpOptionsR3L3Share &= 0b11111101
            } else {
                DPadLeftDownRightUpOptionsR3L3Share |= 0b00000010
            }
        }
    }

    var share: AnalogValue {
        get {
            (DPadLeftDownRightUpOptionsR3L3Share & 0b00000001) > 0
                ? DSUButton.pressed : DSUButton.released
        }
        set {
            if newValue == 0 {
                DPadLeftDownRightUpOptionsR3L3Share &= 0b11111110
            } else {
                DPadLeftDownRightUpOptionsR3L3Share |= 0b00000001
            }
        }
    }
}
