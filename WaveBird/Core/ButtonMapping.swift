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
        case .a: "A Button"
        case .b: "B Button"
        case .x: "X Button"
        case .y: "Y Button"
        case .l: "L Button"
        case .r: "R Button"
        case .zl: "ZL Button"
        case .zr: "ZR Button"
        case .plus: "Plus Button"
        case .minus: "Minus Button"
        case .home: "Home Button"
        case .capture: "Capture Button"
        case .stickL: "Left Stick Click"
        case .stickR: "Right Stick Click"
        case .dpadUp: "D-pad Up"
        case .dpadDown: "D-pad Down"
        case .dpadLeft: "D-pad Left"
        case .dpadRight: "D-pad Right"
        case .c: "C Button"
        case .gl: "GL Button"
        case .gr: "GR Button"
        case .z: "Z Button"
        case .start: "Start Button"
        case .sl: "SL Button"
        case .sr: "SR Button"
        }
    }
}

// One row's stored choice: drive the control from the OR of one or more
// physical sources, or disable it. Absence from the mapping dict = Default
// (copy-through). Persisted as a JSON array of source tokens; ["off"] = off.
enum MappingChoice: Sendable, Hashable, Codable {
    case off
    case sources([MappingSource])

    init(from decoder: any Decoder) throws {
        let tokens = try decoder.singleValueContainer().decode([String].self)
        if tokens.contains("off") {
            self = .off
        } else {
            self = .sources(tokens.compactMap(MappingSource.init(token:)))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .off: try container.encode(["off"])
        case .sources(let sources): try container.encode(sources.map(\.token))
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

extension ControlDriver {
    var isAnalogTrigger: Bool {
        switch self {
        case .leftTrigger, .rightTrigger: true
        default: false
        }
    }
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
    struct Override: Sendable {
        let driver: ControlDriver
        let sources: [MappingSource]   // empty = Off (clear only); non-empty = replace with the OR
    }

    let overrides: [Override]
    var leftStick: StickTransform = .init()
    var rightStick: StickTransform = .init()

    var isDefault: Bool { overrides.isEmpty && leftStick.isIdentity && rightStick.isIdentity }

    static let identity = ResolvedMappingSpec(overrides: [])
}

extension ControllerState {
    // Pre-encode rewrite: runs in the dispatch task after applyingStickTransforms,
    // before buildReport. Reads presses from the ORIGINAL state, writes into a copy —
    // so "A ← ZL" still lets physical ZL drive its own default row too
    // (duplicates allowed, no swap inference).
    func applyingMapping(_ spec: ResolvedMappingSpec) -> ControllerState {
        guard !spec.isDefault else { return self }
        var out = self
        for override in spec.overrides {
            Self.clear(override.driver, in: &out)
        }
        for override in spec.overrides {
            Self.drive(override.driver, from: override.sources, reading: self, into: &out)
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

    // Reads presses/travel from the ORIGINAL state, writes into the copy, so a
    // source can still drive its own default row too. Empty sources = Off:
    // the driver was cleared above and nothing is set.
    private static func drive(_ driver: ControlDriver, from sources: [MappingSource],
                              reading input: ControllerState, into state: inout ControllerState) {
        guard !sources.isEmpty else { return }
        switch driver {
        case .buttons(let members):
            if sources.contains(where: { $0.isPressed(in: input) }) {
                state.buttons.formUnion(members)
            }
        case .leftBumper:
            if sources.contains(where: { $0.isPressed(in: input) }) {
                state.shoulders.leftBumper = true
            }
        case .rightBumper:
            if sources.contains(where: { $0.isPressed(in: input) }) {
                state.shoulders.rightBumper = true
            }
        case .leftTrigger:
            let value = sources.map { $0.analogValue(in: input) }.max() ?? 0
            state.shoulders.leftTriggerAnalog = value
            state.shoulders.leftTriggerDigital = (value == 0xFF)
        case .rightTrigger:
            let value = sources.map { $0.analogValue(in: input) }.max() ?? 0
            state.shoulders.rightTriggerAnalog = value
            state.shoulders.rightTriggerDigital = (value == 0xFF)
        }
    }
}

// Live-updatable spec shared between the main actor (profile edits) and a
// device's off-main dispatch task, which samples `current` per report — the
// same lock-guarded-snapshot idiom as RumbleSettings/XboxOutputSettings.
final class MappingSpecBox: Sendable {
    private let lock: OSAllocatedUnfairLock<ResolvedMappingSpec>

    init(_ initial: ResolvedMappingSpec = .identity) {
        lock = OSAllocatedUnfairLock(initialState: initial)
    }

    var current: ResolvedMappingSpec { lock.withLock { $0 } }
    func update(_ spec: ResolvedMappingSpec) { lock.withLock { $0 = spec } }
}
