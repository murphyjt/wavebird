import Foundation

enum TestRumblePattern: String, CaseIterable, Identifiable, Sendable {
    case both
    case left
    case right
    case alternate
    case ramp

    var id: String { rawValue }
    var label: String {
        switch self {
        case .both:      return "Both"
        case .left:      return "Left"
        case .right:     return "Right"
        case .alternate: return "Alternate"
        case .ramp:      return "Ramp"
        }
    }
}
