import SwiftUI

struct ContentView: View {
    @Bindable var coordinator: BridgeCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WaveBird")
                    .font(.headline)
                Spacer()
                Button(coordinator.isScanning ? "Stop Scan" : "Start Scan") {
                    Task { await coordinator.toggleScan() }
                }
                .controlSize(.large)
            }

            if coordinator.devices.isEmpty {
                Text("No devices yet — start scan and pair a controller")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(coordinator.devices.values)) { record in
                    deviceRow(record)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Last raw report").font(.caption).foregroundStyle(.secondary)
                if let snap = coordinator.lastReportSnapshot {
                    Text("\(snap.data.count) bytes").font(.caption2).foregroundStyle(.secondary)
                    Text(snap.hex)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(8)
                        .textSelection(.enabled)
                } else {
                    Text("—").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Log").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(coordinator.log.indices.reversed(), id: \.self) { i in
                            Text(coordinator.log[i])
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 160)
                .background(Color.secondary.opacity(0.06))
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 560)
    }

    @ViewBuilder
    private func deviceRow(_ record: DeviceRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.profile.name)
                    .font(.subheadline.weight(.semibold))
                Text(stateLabel(record.connectionState))
                    .font(.caption)
                    .foregroundStyle(stateColor(record.connectionState))
                if record.virtualHID != nil {
                    Text("• HID active")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Text("PID 0x\(String(format: "%04X", record.advertisement.productID)) — \(record.id.raw.uuidString.prefix(8))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func stateLabel(_ s: DeviceConnectionState) -> String {
        switch s {
        case .discovered: "discovered"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .failed(let msg): "failed: \(msg)"
        }
    }

    private func stateColor(_ s: DeviceConnectionState) -> Color {
        switch s {
        case .connected: .green
        case .connecting, .discovered: .orange
        case .disconnected: .secondary
        case .failed: .red
        }
    }
}
