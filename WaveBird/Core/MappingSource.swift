import Foundation

// A single physical input a mapping row can draw from: a digital button, or
// GameCube analog trigger travel. Tokens are the persistence format (inside a
// MappingChoice JSON array) — never rename. Analog cases are offered by the
// editor only for analog-trigger outputs (see ControlDriver.isAnalogTrigger).
enum MappingSource: Sendable, Hashable {
    case button(PhysicalButton)
    case leftAnalogTrigger
    case rightAnalogTrigger

    var token: String {
        switch self {
        case .button(let b): b.rawValue
        case .leftAnalogTrigger: "analogL"
        case .rightAnalogTrigger: "analogR"
        }
    }

    init?(token: String) {
        switch token {
        case "analogL": self = .leftAnalogTrigger
        case "analogR": self = .rightAnalogTrigger
        default:
            guard let button = PhysicalButton(rawValue: token) else { return nil }
            self = .button(button)
        }
    }

    var displayName: String {
        switch self {
        case .button(let b): b.displayName
        case .leftAnalogTrigger: "Left Trigger (Analog)"
        case .rightAnalogTrigger: "Right Trigger (Analog)"
        }
    }

    var family: PhysicalButton.Family {
        switch self {
        case .button(let b): b.family
        case .leftAnalogTrigger, .rightAnalogTrigger: .gameCube
        }
    }

    // Digital view: is this source active? Analog cases read >0 travel.
    func isPressed(in state: ControllerState) -> Bool {
        switch self {
        case .button(let b): state.buttons.contains(b.buttonSetMember)
        case .leftAnalogTrigger: state.shoulders.leftTriggerAnalog > 0
        case .rightAnalogTrigger: state.shoulders.rightTriggerAnalog > 0
        }
    }

    // Analog view: 0xFF for a pressed button, else the live trigger travel.
    func analogValue(in state: ControllerState) -> UInt8 {
        switch self {
        case .button(let b): state.buttons.contains(b.buttonSetMember) ? 0xFF : 0
        case .leftAnalogTrigger: state.shoulders.leftTriggerAnalog
        case .rightAnalogTrigger: state.shoulders.rightTriggerAnalog
        }
    }
}
