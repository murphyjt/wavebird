import SwiftUI

// Shown while a single Joy-Con 2 is .ready without its partner. WaveBird
// doesn't create a virtual HID until both sides are paired up, so this sheet
// guides the user to attach the missing side. Auto-dismissed by ContentView
// once the partner arrives (joyConWaitingForPartnerID clears).
struct JoyConPartnerSheet: View {
    let coordinator: BridgeCoordinator
    let connectedSide: Side
    let onDismiss: () -> Void

    enum Side {
        case left, right
        var name: String {
            switch self {
            case .left:  return "Joy-Con 2 (L)"
            case .right: return "Joy-Con 2 (R)"
            }
        }
        var missing: String {
            switch self {
            case .left:  return "Joy-Con 2 (R)"
            case .right: return "Joy-Con 2 (L)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Connect the Other Joy-Con")
                    .font(.headline)
                Text("\(connectedSide.name) is connected. Hold the SYNC Button on the \(connectedSide.missing) to pair it as well — both Joy-Cons combine into a single controller.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 12)
            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 384)
    }
}
