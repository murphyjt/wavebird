import Foundation

struct GameCubeButtons: OptionSet {
    let rawValue: UInt32

    static let b = GameCubeButtons(rawValue: 1 << 0)
    static let a = GameCubeButtons(rawValue: 1 << 1)
    static let y = GameCubeButtons(rawValue: 1 << 2)
    static let x = GameCubeButtons(rawValue: 1 << 3)
    static let r = GameCubeButtons(rawValue: 1 << 4)
    static let z = GameCubeButtons(rawValue: 1 << 5)
    static let start = GameCubeButtons(rawValue: 1 << 6)

    static let dpadDown = GameCubeButtons(rawValue: 1 << (8 + 0))
    static let dpadRight = GameCubeButtons(rawValue: 1 << (8 + 1))
    static let dpadLeft = GameCubeButtons(rawValue: 1 << (8 + 2))
    static let dpadUp = GameCubeButtons(rawValue: 1 << (8 + 3))
    static let l = GameCubeButtons(rawValue: 1 << (8 + 4))
    static let zl = GameCubeButtons(rawValue: 1 << (8 + 5))  // byte 3, bit 5

    static let cButton = GameCubeButtons(rawValue: 1 << (16 + 4))  // byte 4, bit 4
    static let screenshot = GameCubeButtons(rawValue: 1 << (16 + 5))  // byte 4, bit 5
    static let home = GameCubeButtons(rawValue: 1 << (16 + 6))  // byte 4, bit 6
}

struct GameCubeAdapter {
    static func convert(_ data: Data) -> DSUControllerData {
        let raw =
            UInt32(data[2]) | (UInt32(data[3]) << 8) | (UInt32(data[4]) << 16)

        let buttons = GameCubeButtons(rawValue: raw)

        // --- Create DSUControllerData ---
        var report = DSUControllerData()
        report.connected = .connected
        report.packetNumber = UInt32.random(in: 0..<UInt32.max)

        report.homeButton = buttons.contains(.start) ? .pressed : .released

        report.buttonA = buttons.contains(.a) ? .pressed : .released
        report.buttonB = buttons.contains(.b) ? .pressed : .released
        report.buttonX = buttons.contains(.x) ? .pressed : .released
        report.buttonY = buttons.contains(.y) ? .pressed : .released

        report.buttonL1 = buttons.contains(.b) ? .pressed : .released
        report.buttonR1 = buttons.contains(.r) ? .pressed : .released
        report.buttonL1 = buttons.contains(.l) ? .pressed : .released
        report.buttonL2 = buttons.contains(.zl) ? .pressed : .released
        report.buttonR2 = buttons.contains(.z) ? .pressed : .released

        report.dpadUp = buttons.contains(.dpadUp) ? .pressed : .released
        report.dpadDown = buttons.contains(.dpadDown) ? .pressed : .released
        report.dpadLeft = buttons.contains(.dpadLeft) ? .pressed : .released
        report.dpadRight = buttons.contains(.dpadRight) ? .pressed : .released

        // Stick axes (set to neutral for now)
        report.leftStickX = 128
        report.leftStickY = 128
        report.rightStickX = 128
        report.rightStickY = 128

        report.connected = .connected
        report.state = .Connected
        return report
    }
}
