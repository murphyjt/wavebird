import AppKit
import SwiftUI

// Main-window banner shown while coordinator.hidAccessIssue is non-nil. Same
// visual shape as ContentView's transport banner, plus the settings shortcut.
struct HIDAccessBanner: View {
    let issue: HIDAccessIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    // Without this the multi-line message truncates instead
                    // of growing the banner vertically.
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings…", action: openAccessibilitySettings)
                    .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// The post-event permission lives in the Accessibility pane.
@MainActor
func openAccessibilitySettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    NSWorkspace.shared.open(url)
}
