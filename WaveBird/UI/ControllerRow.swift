import SwiftUI

struct LiveControllerRow: View {
    let record: DeviceRecord
    let paired: KnownController?
    // Overrides used when this row stands in for a Joy-Con 2 pair: the L
    // record is the visible row and these substitutions reflect the merged
    // identity + the shared VHID state.
    var displayNameOverride: String? = nil
    var vhidActiveOverride: Bool? = nil
    // When non-nil, this row represents a Joy-Con pair and holding Option
    // swaps the bottom action to Split Paired Controllers. Mirrors macOS's
    // Quit → Force Quit alternate-action convention.
    var optionHeld: Bool = false
    var onSplit: (() -> Void)? = nil
    let onSelect: () -> Void
    let onDisconnect: () -> Void

    private var vhidActive: Bool {
        vhidActiveOverride ?? (record.virtualHID != nil)
    }

    private var displayName: String {
        displayNameOverride ?? paired?.displayName ?? record.profile.name
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(vhidActive ? record.firmware?.controllerType == 0x03 ? .gamecubeIndigo : .nintendoRed : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(.default)
                                .foregroundStyle(.primary)
                        }
                        HStack(spacing: 6) {
                            Circle()
                                .fill(stateColor(record.connectionState))
                                .frame(width: 10, height: 10)
                            Text(stateLabel(record.connectionState))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if record.connectionState == .ready {
                Divider()
                HStack {
                    if optionHeld, let onSplit {
                        Button("Split Paired Controllers", action: onSplit)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Tears down the merged Joy-Con virtual device. Both Joy-Cons stay connected but won't auto-pair again this session.")
                    } else {
                        Button("Disconnect Controller", action: onDisconnect)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Drops the Bluetooth link. Press any button on the controller to reconnect.")
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .background(Color.secondary.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stateLabel(_ s: DeviceConnectionState) -> String {
        switch s {
        case .discovered: "Discovered"
        case .connecting: "Connecting…"
        case .connected, .ready: "Connected"
        case .disconnected: "Not Connected"
        case .failed(let msg): "Failed: \(msg)"
        }
    }

    private func stateColor(_ s: DeviceConnectionState) -> Color {
        switch s {
        case .connected, .ready: .green
        case .connecting, .discovered: .orange
        case .disconnected: .red
        case .failed: .red
        }
    }
}

struct OfflineControllerRow: View {
    let paired: KnownController
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(paired.displayName)
                        .font(.default)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                        Text("Not Connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.065))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


extension Color {
    static let nintendoRed = Color(red: 230/255, green: 0/255, blue: 18/255)
    static let gamecubeIndigo = Color(red: 0.40, green: 0.40, blue: 0.67)
}
