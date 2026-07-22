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

// Which physical stick feeds an output stick (or Off = force neutral). Raw
// values are persistence — never rename.
enum StickSource: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case `default`, off, left, right
    var id: String { rawValue }
}

// Per-stick transform applied before the output encoder. The source physical
// stick is resolved first, then rotation, then axis inversion. Defaulted fields
// so an older profile blob that predates transforms decodes to a no-op.
struct StickTransform: Codable, Sendable, Hashable {
    var source: StickSource = .default
    var invertX: Bool = false
    var invertY: Bool = false
    var rotation: StickRotation = .none

    var isIdentity: Bool { source == .default && !invertX && !invertY && rotation == .none }
}

// invertX/invertY/rotation/source are non-optional with defaults, so the
// synthesized Decodable would reject older blobs missing those keys. This
// tolerant decoder lives in an extension (not the struct body) to preserve the
// compiler-synthesized memberwise initializer existing call sites rely on.
extension StickTransform {
    enum CodingKeys: String, CodingKey {
        case source, invertX, invertY, rotation
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(StickSource.self, forKey: .source) ?? .default
        invertX = try c.decodeIfPresent(Bool.self, forKey: .invertX) ?? false
        invertY = try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? false
        rotation = try c.decodeIfPresent(StickRotation.self, forKey: .rotation) ?? .none
    }
}
