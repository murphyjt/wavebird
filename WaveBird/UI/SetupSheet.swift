import SwiftUI

// Wraps the original "no controller connected" empty-state copy as a sheet
// that can be opened from the header any time. Auto-dismissed by ContentView
// when a new device transitions to .ready while this sheet is open.
struct SetupSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Set up Game Controller")
                    .font(.headline)
                Text("Hold the SYNC Button on the Nintendo Switch 2 Controller that you'd like to pair.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 12)
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 384)
    }
}
