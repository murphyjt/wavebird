import AppKit
import SwiftUI

/// Sparkle-style "update available" panel. Renders the GitHub release notes as
/// Markdown (git-cliff emits `### headings` + `- bullets`), which `NSAlert`'s
/// plain informativeText can't do.
struct UpdateAvailableView: View {
    let version: String
    let currentVersion: String
    let notes: String

    let onDownload: () -> Void
    let onReleaseNotes: () -> Void
    let onSkip: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A new version of WaveBird is available!")
                        .font(.headline)
                    Text("WaveBird \(version) is now available—you have \(currentVersion). Would you like to download it now?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !notes.isEmpty {
                HStack {
                    Text("Release Notes")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Open in Browser", action: onReleaseNotes)
                        .buttonStyle(.link)
                }
                ScrollView {
                    ChangelogView(markdown: notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 220)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }

            HStack {
                Button("Skip This Version", action: onSkip)
                Spacer()
                Button("Later", action: onLater)
                Button("Download", action: onDownload)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Minimal Markdown block renderer: headings, bullets, and blank-line spacing,
/// with inline emphasis/links handled per line by `AttributedString`. Scoped to
/// what git-cliff produces — not a general Markdown engine.
private struct ChangelogView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(for: line)
            }
        }
    }

    private var lines: [String] {
        markdown.components(separatedBy: .newlines)
    }

    @ViewBuilder
    private func row(for raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Spacer().frame(height: 4)
        } else if let (level, text) = heading(line) {
            inline(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 4 : 2)
        } else if let bullet = bullet(line) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(bullet).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            inline(line).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return (hashes, text)
    }

    private func bullet(_ line: String) -> String? {
        for marker in ["- ", "* "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        default: return .headline
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}
