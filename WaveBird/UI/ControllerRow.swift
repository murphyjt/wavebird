import SwiftUI

struct LiveControllerRow: View {
    let record: DeviceRecord
    let paired: PairedController?
    let onSelect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(record.virtualHID != nil ? record.firmware?.controllerType == 0x03 ? .gamecubeIndigo : .nintendoRed : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(paired?.displayName ?? record.profile.name)
                                .font(.default)
                                .foregroundStyle(.primary)
                            if paired != nil { PairedBadge() }
                        }
                        HStack(spacing: 6) {
                            Circle()
                                .fill(stateColor(record.connectionState))
                                .frame(width: 10, height: 10)
                            Text(stateLabel(record.connectionState))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if record.connectionState == .ready, record.reportRate > 0 {
                                HStack(spacing: 4) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text("\(Int(record.reportRate)) Hz")
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
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
                    Button("Disconnect Controller", action: onDisconnect)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Drops the BLE link. Press any button on the controller to reconnect.")
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
        case .disconnected: "Disconnected"
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
    let paired: PairedController
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
                    HStack(spacing: 6) {
                        Text(paired.displayName)
                            .font(.default)
                            .foregroundStyle(.primary)
                        PairedBadge()
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 10, height: 10)
                        Text("Disconnected")
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
            .opacity(0.75)
        }
        .buttonStyle(.plain)
    }
}

struct PairedBadge: View {
    var body: some View {
        Text("Paired")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.18))
            .foregroundStyle(.green)
            .clipShape(Capsule())
    }
}

extension Color {
    static let nintendoRed = Color(red: 230/255, green: 0/255, blue: 18/255)
    static let gamecubeIndigo = Color(red: 0.40, green: 0.40, blue: 0.67)
}
