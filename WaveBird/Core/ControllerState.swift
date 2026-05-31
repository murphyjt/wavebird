import Foundation

struct ButtonSet: OptionSet, Sendable, Hashable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    static let a         = ButtonSet(rawValue: 1 << 0)
    static let b         = ButtonSet(rawValue: 1 << 1)
    static let x         = ButtonSet(rawValue: 1 << 2)
    static let y         = ButtonSet(rawValue: 1 << 3)
    static let l         = ButtonSet(rawValue: 1 << 4)
    static let r         = ButtonSet(rawValue: 1 << 5)
    static let zl        = ButtonSet(rawValue: 1 << 6)
    static let zr        = ButtonSet(rawValue: 1 << 7)
    static let minus     = ButtonSet(rawValue: 1 << 8)
    static let plus      = ButtonSet(rawValue: 1 << 9)
    static let stickL    = ButtonSet(rawValue: 1 << 10)
    static let stickR    = ButtonSet(rawValue: 1 << 11)
    static let dpadUp    = ButtonSet(rawValue: 1 << 12)
    static let dpadDown  = ButtonSet(rawValue: 1 << 13)
    static let dpadLeft  = ButtonSet(rawValue: 1 << 14)
    static let dpadRight = ButtonSet(rawValue: 1 << 15)
    static let home      = ButtonSet(rawValue: 1 << 16)
    static let capture   = ButtonSet(rawValue: 1 << 17)
    static let z         = ButtonSet(rawValue: 1 << 18)
    static let start     = ButtonSet(rawValue: 1 << 19)
    static let c         = ButtonSet(rawValue: 1 << 20)
    static let sl        = ButtonSet(rawValue: 1 << 21)
    static let sr        = ButtonSet(rawValue: 1 << 22)
}

struct IMUSample: Sendable, Hashable {
    var accelX: Int16
    var accelY: Int16
    var accelZ: Int16
    var gyroX:  Int16
    var gyroY:  Int16
    var gyroZ:  Int16
}

struct ControllerState: Sendable {
    // Stick axes as a centered 12-bit value: working range -2047...2047,
    // neutral 0, "positive Y = up" (our game-friendly convention; output
    // sessions invert for HID's positive-Y-down where needed). This preserves
    // the controller's native 12-bit resolution end-to-end — output encoders
    // scale down to their wire width (8-bit PlayStation, 16-bit Xbox) and the
    // Switch Pro 12-bit path is bit-exact (re-add 2048). The symmetric range
    // also has no Int.min edge, so negating an axis can't overflow.
    var leftStick:   SIMD2<Int16>
    var rightStick:  SIMD2<Int16>
    var triggerL:    UInt8
    var triggerR:    UInt8
    var buttons:     ButtonSet
    var imu:         IMUSample?
    var timestamp:   ContinuousClock.Instant
    // Normalized shoulder/trigger roles. Input parsers populate this from each
    // controller's native button layout so output sessions don't need to
    // translate Nintendo ZL/Z/L/R semantics themselves.
    var shoulders:   StandardShoulders = StandardShoulders()

    static var zero: ControllerState {
        ControllerState(
            leftStick:  .zero,
            rightStick: .zero,
            triggerL:   0,
            triggerR:   0,
            buttons:    [],
            imu:        nil,
            timestamp:  .now
        )
    }

    // Flip the sign of the requested stick Y axes (our convention is "positive
    // Y = up", so negating inverts). Applied to the parsed state before the
    // output session encodes it, so inversion is presentation-agnostic.
    func invertingY(left: Bool, right: Bool) -> ControllerState {
        guard left || right else { return self }
        var copy = self
        if left  { copy.leftStick.y  = Self.negate(copy.leftStick.y) }
        if right { copy.rightStick.y = Self.negate(copy.rightStick.y) }
        return copy
    }

    // Negation is exact across the symmetric -2047...2047 working range; the
    // clamp is belt-and-suspenders against an out-of-range axis.
    private static func negate(_ v: Int16) -> Int16 { Int16(clamping: -Int(v)) }
}
