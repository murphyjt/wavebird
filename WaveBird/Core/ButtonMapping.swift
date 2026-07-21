import Foundation
import os

// The Nintendo-side vocabulary a mapping profile's dropdown draws from — the
// union of every supported controller's physical buttons. A profile row
// sourced from a button the connected controller lacks simply never fires.
// Raw values are the persistence format (MappingProfile JSON): never rename.
enum PhysicalButton: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case a, b, x, y
    case l, r, zl, zr
    case plus, minus, home, capture
    case stickL, stickR
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case c
    case gl, gr          // NS2 Pro rear grips
    case z, start        // GameCube
    case sl, sr          // Joy-Con side rails

    var id: String { rawValue }

    // The parsed ButtonSet member that reports this button's press. Note GC's
    // L/R are analog clicks — reading the ButtonSet member means "full click".
    var buttonSetMember: ButtonSet {
        switch self {
        case .a: .a
        case .b: .b
        case .x: .x
        case .y: .y
        case .l: .l
        case .r: .r
        case .zl: .zl
        case .zr: .zr
        case .plus: .plus
        case .minus: .minus
        case .home: .home
        case .capture: .capture
        case .stickL: .stickL
        case .stickR: .stickR
        case .dpadUp: .dpadUp
        case .dpadDown: .dpadDown
        case .dpadLeft: .dpadLeft
        case .dpadRight: .dpadRight
        case .c: .c
        case .gl: .gl
        case .gr: .gr
        case .z: .z
        case .start: .start
        case .sl: .sl
        case .sr: .sr
        }
    }

    // Editor dropdown grouping.
    enum Family: String, CaseIterable, Identifiable {
        case common = "Common"
        case pro = "Pro Controller"
        case gameCube = "GameCube"
        case joyCon = "Joy-Con"
        var id: String { rawValue }
    }

    var family: Family {
        switch self {
        case .gl, .gr: .pro
        case .z, .start: .gameCube
        case .sl, .sr: .joyCon
        default: .common
        }
    }

    var displayName: String {
        switch self {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .l: "L"
        case .r: "R"
        case .zl: "ZL"
        case .zr: "ZR"
        case .plus: "Plus"
        case .minus: "Minus"
        case .home: "Home"
        case .capture: "Capture"
        case .stickL: "Left Stick Click"
        case .stickR: "Right Stick Click"
        case .dpadUp: "D-pad Up"
        case .dpadDown: "D-pad Down"
        case .dpadLeft: "D-pad Left"
        case .dpadRight: "D-pad Right"
        case .c: "C"
        case .gl: "GL"
        case .gr: "GR"
        case .z: "Z"
        case .start: "Start"
        case .sl: "SL"
        case .sr: "SR"
        }
    }
}

// One row's stored choice in a MappingProfile: drive the control from a
// physical button, or disable it outright. Absence from the dict = Default.
enum MappingChoice: RawRepresentable, Codable, Sendable, Hashable {
    case off
    case physical(PhysicalButton)

    var rawValue: String {
        switch self {
        case .off: "off"
        case .physical(let button): button.rawValue
        }
    }

    init?(rawValue: String) {
        if rawValue == "off" {
            self = .off
        } else if let button = PhysicalButton(rawValue: rawValue) {
            self = .physical(button)
        } else {
            return nil
        }
    }
}

// Which canonical ControllerState field an output mode's encoder reads for a
// given control. `.buttons` may carry several ButtonSet members when the
// encoder ORs them (e.g. Xbox Menu reads .plus OR .start) — clearing/setting
// the driver touches all of them together.
enum ControlDriver: Sendable, Hashable {
    case buttons(ButtonSet)
    case leftBumper
    case rightBumper
    case leftTrigger
    case rightTrigger
}

// One remappable row of an output mode: stable ID (persistence key — never
// rename), display name (editor row label), and the driver its encoder reads.
// Default source is copy-through of the driver field, not a stored button:
// shoulder defaults differ per input controller (Pro bumper ← L, GC bumper ←
// ZL), and copy-through also preserves GC's analog triggers on Default.
struct OutputControl: Sendable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let driver: ControlDriver
}

// A profile's mapping compiled against its base mode's control catalog.
// Only non-Default rows become overrides: Default rows need no entry because
// the untouched state already carries the parser's wiring (copy-through).
// Empty overrides == the stock profile — the transform is a guaranteed no-op
// so the default hot path stays bit-exact.
struct ResolvedMappingSpec: Sendable {
    enum Source: Sendable, Hashable {
        case off
        case physical(PhysicalButton)
    }

    struct Override: Sendable {
        let driver: ControlDriver
        let source: Source
    }

    let overrides: [Override]
    var leftStick: StickTransform = .init()
    var rightStick: StickTransform = .init()

    var isDefault: Bool { overrides.isEmpty && leftStick.isIdentity && rightStick.isIdentity }

    static let identity = ResolvedMappingSpec(overrides: [])
}

extension ControllerState {
    // Pre-encode rewrite: runs in the dispatch task after invertingY, before
    // buildReport. Reads presses from the ORIGINAL state, writes into a copy —
    // so "A ← ZL" still lets physical ZL drive its own default row too
    // (duplicates allowed, no swap inference).
    func applyingMapping(_ spec: ResolvedMappingSpec) -> ControllerState {
        guard !spec.isDefault else { return self }
        var out = self
        for override in spec.overrides {
            Self.clear(override.driver, in: &out)
        }
        for override in spec.overrides {
            guard case .physical(let button) = override.source,
                  buttons.contains(button.buttonSetMember) else { continue }
            Self.set(override.driver, in: &out)
        }
        return out.applyingStickTransforms(left: spec.leftStick, right: spec.rightStick)
    }

    private static func clear(_ driver: ControlDriver, in state: inout ControllerState) {
        switch driver {
        case .buttons(let members):
            state.buttons.subtract(members)
        case .leftBumper:
            state.shoulders.leftBumper = false
        case .rightBumper:
            state.shoulders.rightBumper = false
        case .leftTrigger:
            state.shoulders.leftTriggerDigital = false
            state.shoulders.leftTriggerAnalog = 0
        case .rightTrigger:
            state.shoulders.rightTriggerDigital = false
            state.shoulders.rightTriggerAnalog = 0
        }
    }

    private static func set(_ driver: ControlDriver, in state: inout ControllerState) {
        switch driver {
        case .buttons(let members):
            state.buttons.formUnion(members)
        case .leftBumper:
            state.shoulders.leftBumper = true
        case .rightBumper:
            state.shoulders.rightBumper = true
        case .leftTrigger:
            state.shoulders.leftTriggerDigital = true
            state.shoulders.leftTriggerAnalog = 0xFF
        case .rightTrigger:
            state.shoulders.rightTriggerDigital = true
            state.shoulders.rightTriggerAnalog = 0xFF
        }
    }
}

// Live-updatable spec shared between the main actor (profile edits) and a
// device's off-main dispatch task, which samples `current` per report — the
// same lock-guarded-snapshot idiom as AxisSettings/RumbleSettings.
final class MappingSpecBox: Sendable {
    private let lock: OSAllocatedUnfairLock<ResolvedMappingSpec>

    init(_ initial: ResolvedMappingSpec = .identity) {
        lock = OSAllocatedUnfairLock(initialState: initial)
    }

    var current: ResolvedMappingSpec { lock.withLock { $0 } }
    func update(_ spec: ResolvedMappingSpec) { lock.withLock { $0 = spec } }
}
