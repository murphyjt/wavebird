import SwiftUI

// Modal shown the first time a not-yet-paired NS2 controller becomes .ready.
// The exchange happens via the same BLE command channel the rest of init
// uses; the controller stays usable throughout because input reports flow on
// a separate characteristic and aren't disturbed by the pairing handshake.
//
// Pairing overwrites the controller's existing pairing entries, including its
// pairing with a Nintendo Switch 2 console. The sheet calls this out so users
// aren't surprised when their controller stops auto-reconnecting to a console.
struct PairingSheet: View {
    @Bindable var coordinator: BridgeCoordinator
    let prompt: PairingPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(titlePrefix) \(prompt.controllerName)?")
                        .font(.headline)
                    Text("SN \(prompt.serial)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }

            Text(bodyCopy)
                .font(.callout)

            if showsOverwriteWarning {
                GroupBox {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Pairing will overwrite the controller's pairing with a Nintendo Switch 2 console. To use it on the console again, you'll need to re-pair it there (hold SYNC).")
                            .font(.caption)
                    }
                }
            }

            if case .failed(let message) = prompt.status {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Not Now") {
                    coordinator.declinePairing()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(prompt.status == .inProgress)

                Button {
                    Task { await coordinator.acceptPairing() }
                } label: {
                    if prompt.status == .inProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(acceptLabel)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.status == .inProgress)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var iconName: String {
        switch prompt.intent {
        case .pair, .repair: "link.badge.plus"
        case .remember:      "questionmark.folder"
        }
    }

    private var titlePrefix: String {
        switch prompt.intent {
        case .pair:     "Pair"
        case .repair:   "Re-pair"
        case .remember: "Remember"
        }
    }

    private var acceptLabel: String {
        switch prompt.intent {
        case .pair:     "Pair"
        case .repair:   "Re-pair"
        case .remember: "Remember"
        }
    }

    private var bodyCopy: String {
        switch prompt.intent {
        case .pair:
            "Pairing lets WaveBird remember this controller, so you can reconnect by pressing any button instead of holding SYNC."
        case .repair:
            "WaveBird remembers this controller, but the controller no longer recognizes this Mac — probably because it was paired with another device. Re-pair to restore auto-reconnect."
        case .remember:
            "This controller is already paired to this Mac at the hardware level, but WaveBird doesn't have a record of it. Add it to WaveBird's list? No re-pairing is needed."
        }
    }

    private var showsOverwriteWarning: Bool {
        switch prompt.intent {
        case .pair, .repair: true
        case .remember:      false
        }
    }
}
