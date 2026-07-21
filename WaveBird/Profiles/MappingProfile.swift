import Foundation

// A named, reusable button mapping with a fixed base emulated controller.
// Built-ins ("Default Xbox …") are synthesized from the output catalog under
// well-known IDs and never stored; customs persist via MappingProfileStore.
// `mapping` is sparse: absent control ID = Default (copy-through wiring).
struct MappingProfile: Codable, Sendable, Hashable, Identifiable {
    var id: String            // "default.<modeID>" for built-ins; UUID string for customs
    var name: String
    var baseModeID: String    // HIDOutputCatalog entry ID; fixed after creation
    var mapping: [String: MappingChoice] = [:]
    var symbolName: String? = nil   // nil → synthesize from base mode
    var colorID: String? = nil      // ProfileColor rawValue; nil/unknown → base default
    var leftStick: StickTransform = .init()
    var rightStick: StickTransform = .init()
    var useNintendoLayout: Bool = false

    static let defaultIDPrefix = "default."

    static func defaultProfileID(forModeID modeID: String) -> String {
        defaultIDPrefix + modeID
    }

    var isBuiltIn: Bool { id.hasPrefix(Self.defaultIDPrefix) }
}

// leftStick/rightStick are non-optional with defaults, so the synthesized
// Decodable would reject older blobs missing those keys. This tolerant
// decoder lives in an extension (not the struct body) to preserve the
// compiler-synthesized memberwise initializer existing call sites rely on.
extension MappingProfile {
    enum CodingKeys: String, CodingKey {
        case id, name, baseModeID, mapping, symbolName, colorID, leftStick, rightStick, useNintendoLayout
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseModeID = try c.decode(String.self, forKey: .baseModeID)
        mapping = try c.decodeIfPresent([String: MappingChoice].self, forKey: .mapping) ?? [:]
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName)
        colorID = try c.decodeIfPresent(String.self, forKey: .colorID)
        leftStick = try c.decodeIfPresent(StickTransform.self, forKey: .leftStick) ?? .init()
        rightStick = try c.decodeIfPresent(StickTransform.self, forKey: .rightStick) ?? .init()
        useNintendoLayout = try c.decodeIfPresent(Bool.self, forKey: .useNintendoLayout) ?? false
    }
}

extension ResolvedMappingSpec {
    // Compile a profile against its base mode's control catalog. Entries whose
    // control ID isn't in the catalog (stale data from a future version) are
    // ignored rather than failing the whole profile.
    static func resolve(profile: MappingProfile) -> ResolvedMappingSpec {
        let controls = MappingControls.controls(forModeID: profile.baseModeID)
        var overrides: [Override] = []
        for control in controls {
            guard let choice = profile.mapping[control.id] else { continue }
            switch choice {
            case .off:
                overrides.append(Override(driver: control.driver, sources: []))
            case .sources(let sources):
                guard !sources.isEmpty else { continue }   // empty = Default (defensive)
                overrides.append(Override(driver: control.driver, sources: sources))
            }
        }
        if profile.useNintendoLayout {
            let byLabel = MappingControls.nintendoLayoutSources(forModeID: profile.baseModeID)
            for control in controls {
                guard let source = byLabel[control.id],          // a diamond face control
                      profile.mapping[control.id] == nil         // still Default (not user-overridden)
                else { continue }
                overrides.append(Override(driver: control.driver, sources: [source]))
            }
        }
        return ResolvedMappingSpec(overrides: overrides,
                                   leftStick: profile.leftStick,
                                   rightStick: profile.rightStick)
    }
}
