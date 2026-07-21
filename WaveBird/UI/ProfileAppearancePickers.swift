import SwiftUI

// Symbol picker: a quick brand row + an ellipsis that opens the fuller grid.
struct ProfileSymbolPicker: View {
    @Binding var symbolName: String
    let tint: Color
    @State private var showMore = false

    private let cell: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProfileSymbol.quick, id: \.self) { name in
                swatch(name)
            }
            Button {
                showMore = true
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: cell, height: cell)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(Color.secondary.opacity(0.15)))
            .popover(isPresented: $showMore, arrowEdge: .bottom) {
                grid
                    .padding(12)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell + 6), spacing: 10), count: 6), spacing: 10) {
            ForEach(ProfileSymbol.all, id: \.self) { name in
                Button {
                    symbolName = name
                    showMore = false
                } label: {
                    Image(systemName: name)
                        .frame(width: cell, height: cell)
                        .foregroundStyle(name == symbolName ? tint : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 6 * (cell + 16))
    }

    private func swatch(_ name: String) -> some View {
        Button {
            symbolName = name
        } label: {
            Image(systemName: name)
                .foregroundStyle(name == symbolName ? tint : .primary)
                .frame(width: cell, height: cell)
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(Circle().strokeBorder(name == symbolName ? tint : .clear, lineWidth: 2))
        )
    }
}

// Color picker: a single tinted pill that opens a swatch grid popover.
struct ProfileColorPicker: View {
    @Binding var colorID: String
    @State private var showPalette = false

    private var selected: ProfileColor { ProfileColor(rawValue: colorID) ?? .automatic }

    var body: some View {
        Button {
            showPalette = true
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected.color)
                .frame(width: 42, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPalette, arrowEdge: .bottom) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 12), count: 4), spacing: 12) {
                ForEach(ProfileColor.allCases) { swatch in
                    Button {
                        colorID = swatch.rawValue
                        showPalette = false
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(swatch == selected ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }
}
