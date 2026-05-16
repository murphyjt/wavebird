import SwiftUI

struct ContentView: View {
    @Bindable var coordinator: BridgeCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if coordinator.devices.isEmpty {
                emptyState
            } else {
                deviceList
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Controllers")
                    .font(.headline)
            }
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .symbolEffect(.pulse, isActive: coordinator.isScanning)
                .foregroundStyle(coordinator.isScanning ? .green : .secondary)
            Button(coordinator.isScanning ? "Stop Scan" : "Start Scan") {
                Task { await coordinator.toggleScan() }
            }
//            .buttonStyle(.glass)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No controller connected")
                .font(.headline)
            Text("Hold the SYNC Button on the Nintendo Switch 2 Controller that you'd like to pair.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                
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
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(record.virtualHID != nil ? record.firmware?.controllerType == 0x03 ? .gamecubeIndigo : .nintendoRed : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.profile.name)
                    .font(.default)
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
                            Text("(\(Int(record.controllerRate)) ctrl)")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Text("Present as")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { record.outputModeID },
                    set: { id in
                        Task { await coordinator.setOutputMode(id, for: record.id) }
                    }
                )) {
                    ForEach(coordinator.catalog.entries) { entry in
                        Text(entry.displayName).tag(entry.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .fixedSize()
        }
        .padding(10)
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

extension Color {
    static let nintendoRed = Color(red: 230/255, green: 0/255, blue: 18/255)
    static let gamecubeIndigo = Color(red: 0.40, green: 0.40, blue: 0.67)
}
