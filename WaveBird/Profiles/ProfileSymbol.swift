import Foundation

// Curated, extensible SF Symbol set for profile identity. `quick` is the inline
// row (controller brands); `all` is what the "more" popover shows. Add names to
// `more` to extend the picker — no picker-code change needed. All names are
// known to exist in SF Symbols; unknown names would render blank.
enum ProfileSymbol {
    static let quick: [String] = [
        "xbox.logo",
        "playstation.logo",
        "gamecontroller.fill",
        "formfitting.gamecontroller.fill",
    ]

    static let more: [String] = [
        "l.joystick.press.down.fill",
        "dpad.fill",
        "arcade.stick",
        "arcade.stick.console.fill",
        "headphones",
        "bolt.fill",
        "star.fill",
        "flag.fill",
        "trophy.fill",
        "target",
        "circle.hexagongrid.fill",
        "flame.fill",
    ]

    static var all: [String] { quick + more }

    // Default symbol + tint synthesized for a profile that hasn't chosen its own
    // (built-ins never store appearance; customs fall back to their base mode's).
    static func defaultAppearance(forBaseModeID id: String) -> (symbol: String, color: ProfileColor) {
        switch id {
        case "xboxSeries":            ("xbox.logo", .green)
        case "dualShock4", "dualSense": ("playstation.logo", .blue)
        case "switchPro":             ("gamecontroller.fill", .red)
        default:                      ("gamecontroller.fill", .gray)
        }
    }
}
