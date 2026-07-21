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
        // D-pad + stick clicks
        "l3": "l.joystick.press.down", "r3": "r.joystick.press.down",
    ]
}
