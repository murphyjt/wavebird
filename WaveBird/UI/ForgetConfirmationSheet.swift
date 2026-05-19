import SwiftUI

struct ForgetConfirmationSheet: View {
    let displayName: String
    let onForget: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 8) {
                Text("Are you sure you want to forget \u{201C}\(displayName)\u{201D}?")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(2)
                Text("This device will not reconnect automatically. You will have to connect it again if you want to use it later.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            VStack(spacing: 6) {
                Button(action: onForget) {
                    Text("Forget Device").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                Button(action: onCancel) {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(width: 256)
    }
}
