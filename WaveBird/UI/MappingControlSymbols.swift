import AppKit

// SF Symbol glyph for an emulated control row, keyed by the control ID's suffix
// (the token after the mode prefix). Only names known to exist in SF Symbols are
// returned; anything without a faithful glyph returns nil so the row stays
// text-only (the glyph is an accent, never the sole signifier).
enum MappingControlSymbols {
    static func symbol(forControlID id: String) -> String? {
        guard let suffix = id.split(separator: ".").last.map(String.init) else { return nil }
        return bySuffix[suffix]
    }

    private static let bySuffix: [String: String] = [
        // Xbox / Switch face buttons
        "a": "a.circle", "b": "b.circle", "x": "x.circle", "y": "y.circle",
        // PlayStation shapes
        "cross": "xmark", "circle": "circle", "square": "square", "triangle": "triangle",
        // Stick clicks
        "l3": "l.joystick.press.down", "r3": "r.joystick.press.down",
        // Xbox shoulders + triggers
        "leftBumper": "lb.rectangle.roundedbottom", "rightBumper": "rb.rectangle.roundedbottom",
        "leftTrigger": "lt.rectangle.roundedtop", "rightTrigger": "rt.rectangle.roundedtop",
        // PlayStation shoulders + triggers
        "l1": "l1.rectangle.roundedbottom", "r1": "r1.rectangle.roundedbottom",
        "l2": "l2.rectangle.roundedtop", "r2": "r2.rectangle.roundedtop",
        // Switch Pro shoulders + triggers
        "l": "l.rectangle.roundedbottom", "r": "r.rectangle.roundedbottom",
        "zl": "zl.rectangle.roundedtop", "zr": "zr.rectangle.roundedtop",
        // Switch Pro system buttons
        "plus": "plus.circle", "minus": "minus.circle",
        "home": "house.circle", "capture": "square.circle",
        // Xbox system buttons (glyphs mirror the printed button icons)
        "view": "square.on.square", "menu": "line.3.horizontal",
        "guide": xboxLogo, "share": "square.and.arrow.up",
    ]

    // SF Symbols 8 renamed logo.xbox → xbox.logo; the new name only resolves on
    // OSes shipping SF Symbols 8+, while logo.xbox is deprecated-but-still-rendering
    // everywhere. Pick the new name where present, else the alias — so the Guide
    // glyph is correct on the macOS 26 deployment baseline and newer alike.
    private static let xboxLogo: String =
        NSImage(systemSymbolName: "xbox.logo", accessibilityDescription: nil) != nil
            ? "xbox.logo" : "logo.xbox"
}
