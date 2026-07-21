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

    static let defaultIDPrefix = "default."

    static func defaultProfileID(forModeID modeID: String) -> String {
        defaultIDPrefix + modeID
    }

    var isBuiltIn: Bool { id.hasPrefix(Self.defaultIDPrefix) }
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
                overrides.append(Override(driver: control.driver, source: .off))
            case .physical(let button):
                overrides.append(Override(driver: control.driver, source: .physical(button)))
            }
        }
        return ResolvedMappingSpec(overrides: overrides)
    }
}
