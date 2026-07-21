import SwiftUI

// Named tint swatches for profile symbols. Stored by name (rawValue) so the
// palette stays stable and theme-aware across releases rather than baking RGB.
// `.automatic` (first swatch) means "no explicit tint" — resolves to the accent.
enum ProfileColor: String, CaseIterable, Sendable, Identifiable {
    case automatic
    case red, orange, yellow, green, mint, teal, cyan
    case blue, indigo, purple, pink, brown, gray, lime, slate

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .automatic: .accentColor
        case .red:       .red
        case .orange:    .orange
        case .yellow:    .yellow
        case .green:     .green
        case .mint:      .mint
        case .teal:      .teal
        case .cyan:      .cyan
        case .blue:      .blue
        case .indigo:    .indigo
        case .purple:    .purple
        case .pink:      .pink
        case .brown:     .brown
        case .gray:      .gray
        case .lime:      Color(red: 0.68, green: 0.82, blue: 0.36)
        case .slate:     Color(red: 0.44, green: 0.50, blue: 0.56)
        }
    }
}
