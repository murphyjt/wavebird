import Foundation

// Rigid stick reorientation. Raw values are persistence format — never rename.
enum StickRotation: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case none, cw90, deg180, ccw90
    var id: String { rawValue }

    var degrees: Int {
        switch self {
        case .none: 0
        case .cw90: 90
        case .deg180: 180
        case .ccw90: 270
        }
    }
}

// Per-stick transform applied before the output encoder. Rotation is applied
// first, then axis inversion. Defaulted fields so an older profile blob that
// predates transforms decodes to a no-op.
struct StickTransform: Codable, Sendable, Hashable {
    var invertX: Bool = false
    var invertY: Bool = false
    var rotation: StickRotation = .none

    var isIdentity: Bool { !invertX && !invertY && rotation == .none }
}
