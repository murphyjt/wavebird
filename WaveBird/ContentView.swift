import SwiftUI

struct ContentView: View {
    @Bindable var coordinator: BridgeCoordinator
    @State private var showDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if coordinator.devices.isEmpty {
                emptyState
            } else {
                deviceList
            }
            Spacer(minLength: 0)
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                diagnosticsView.padding(.top, 8)
            }
            .font(.subheadline)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("WaveBird")
                    .font(.title3.weight(.semibold))
                Text("Nintendo Switch 2 Controller bridge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .symbolEffect(.pulse, isActive: coordinator.isScanning)
                .foregroundStyle(coordinator.isScanning ? .green : .secondary)
            Button(coordinator.isScanning ? "Stop Scan" : "Start Scan") {
                Task { await coordinator.toggleScan() }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No controller connected")
                .font(.headline)
            Text("Hold the SYNC Button on the Nintendo Switch 2 Controller that you'd like to pair. Only the GameCube controller is supported in this version.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var deviceList: some View {
        VStack(spacing: 8) {
            ForEach(Array(coordinator.devices.values)) { record in
                deviceCard(record)
            }
        }
    }

    @ViewBuilder
    private func deviceCard(_ record: DeviceRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.title2)
                .foregroundStyle(record.virtualHID != nil ? .green : .secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.profile.name)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor(record.connectionState))
                        .frame(width: 7, height: 7)
                    Text(stateLabel(record.connectionState))
                        .font(.caption)
                        .foregroundStyle(stateColor(record.connectionState))
                    if record.virtualHID != nil {
                        Text("•").foregroundStyle(.secondary)
                        Text("HID active")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            Spacer()
            if record.connectionState == .ready, record.reportRate > 0 {
                Text("\(Int(record.reportRate)) Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last report")
                    .font(.caption2).foregroundStyle(.secondary)
                if let snap = coordinator.lastReportSnapshot {
                    Text("\(snap.data.count) bytes")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(snap.hex)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(8)
                        .textSelection(.enabled)
                } else {
                    Text("—").font(.caption2).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Log").font(.caption2).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(coordinator.log.indices.reversed(), id: \.self) { i in
                            Text(coordinator.log[i])
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 140)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
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
        case .disconnected: .secondary
        case .failed: .red
        }
    }
}
