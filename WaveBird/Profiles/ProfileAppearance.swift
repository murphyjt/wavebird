import SwiftUI

// Effective symbol + tint for a profile: its explicit choice if set, otherwise
// the synthesized default for its base mode. One resolver used by the Settings
// list, the detail pane, and the "Use profile" pickers so identity is uniform.
struct ProfileAppearance {
    let symbolName: String
    let tint: ProfileColor
    var color: Color { tint.color }

    static func resolve(_ profile: MappingProfile) -> ProfileAppearance {
        let base = ProfileSymbol.defaultAppearance(forBaseModeID: profile.baseModeID)
        let symbol = profile.symbolName ?? base.symbol
        let tint = profile.colorID.flatMap(ProfileColor.init(rawValue:)) ?? base.color
        return ProfileAppearance(symbolName: symbol, tint: tint)
    }
}
