import SwiftUI

struct LiveControllerRow: View {
    let record: DeviceRecord
    let paired: KnownController?
    // VHID-active state, resolved by the coordinator from the live record. The
    // row never sees the VirtualHIDDevice itself (DeviceRecord hands the view a
    // wrapper-free copy) so a retained row can't pin the CoreHID device alive
    // past disconnect.
    let isVHIDActive: Bool
    // Overrides used when this row stands in for a Joy-Con 2 pair: the L
    // record is the visible row and these substitutions reflect the merged
    // identity + the shared VHID state.
    var displayNameOverride: String? = nil
    var vhidActiveOverride: Bool? = nil
    var onSplit: (() -> Void)? = nil
    let onSelect: () -> Void
    let onDisconnect: () -> Void
    var onForget: (() -> Void)? = nil

    private var vhidActive: Bool {
        vhidActiveOverride ?? isVHIDActive
    }

    private var displayName: String {
        displayNameOverride ?? paired?.displayName ?? record.profile.name
    }

    var body: some View {
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
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: 6) {
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
            .padding(.vertical, 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if record.connectionState == .ready {
                Button("Disconnect Controller", action: onDisconnect)
                if let onSplit {
                    Button("Split Paired Controllers", action: onSplit)
                }
                Divider()
            }
            if let onForget {
                Button("Forget Controller", role: .destructive, action: onForget)
            }
        }
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
}

struct OfflineControllerRow: View {
    let paired: KnownController
    let onSelect: () -> Void
    let onForget: () -> Void

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
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
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
            .padding(.vertical, 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Forget Controller", role: .destructive, action: onForget)
        }
    }
}


extension Color {
    static let nintendoRed = Color(red: 230/255, green: 0/255, blue: 18/255)
    static let gamecubeIndigo = Color(red: 0.40, green: 0.40, blue: 0.67)
}
