import SwiftUI

struct ContentView: View {
    @Bindable var coordinator: BridgeCoordinator
    @State private var sheetDeviceID: DeviceID?

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
        .sheet(item: $sheetDeviceID) { id in
            if let record = coordinator.devices[id] {
                ControllerDetailSheet(coordinator: coordinator, record: record) {
                    sheetDeviceID = nil
                }
            }
        }
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
        Button {
            sheetDeviceID = record.id
        } label: {
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
                        .foregroundStyle(.primary)
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
            .background(Color.secondary.opacity(0.065))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

// Per-controller settings sheet. Modelled after macOS System Settings → Game Controllers:
// title bar with controller name + Done, then a stack of sections (Present as, live rumble
// meter, rumble tuning, test patterns). All controller-specific UI lives here.
private struct ControllerDetailSheet: View {
    let coordinator: BridgeCoordinator
    let record: DeviceRecord
    let onDismiss: () -> Void

    var body: some View {
        let settings = coordinator.rumbleSettings(for: record)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(record.profile.name)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }

            // Present as
            HStack(spacing: 8) {
                Text("Present as")
                    .font(.callout)
                Spacer()
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
                .fixedSize()
            }

            // Live rumble meter
            if record.connectionState == .ready {
                RumbleMeterView(
                    latest: record.latestRumble,
                    lastUpdate: record.latestRumbleAt,
                    tint: record.firmware?.controllerType == 0x03 ? .gamecubeIndigo : .nintendoRed
                )
            }

            // Rumble tuning
            RumbleSettingsCard(coordinator: coordinator, record: record, settings: settings)
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 520)
    }
}

private struct RumbleSettingsCard: View {
    let coordinator: BridgeCoordinator
    let record: DeviceRecord
    @Bindable var settings: RumbleSettings

    private static let sliderLabelWidth: CGFloat = 64
    private static let sliderReadoutWidth: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pro Rumble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $settings.preset) {
                    ForEach(RumbleSettings.Preset.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            sliderRow(
                label: "Intensity",
                value: $settings.intensity,
                range: 0...1,
                readout: "\(Int(settings.intensity * 100))%"
            )
            freqSliderRow(label: "Left freq",  value: $settings.leftHiFreq)
            freqSliderRow(label: "Right freq", value: $settings.rightHiFreq)
            ampPairRow(label: "Left amp",  hi: $settings.leftHiAmpScale,  lo: $settings.leftLoAmpScale)
            ampPairRow(label: "Right amp", hi: $settings.rightHiAmpScale, lo: $settings.rightLoAmpScale)
            HStack(spacing: 6) {
                Text("Test")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.sliderLabelWidth, alignment: .leading)
                ForEach(TestRumblePattern.allCases) { pattern in
                    Button(pattern.label) {
                        coordinator.playTestRumble(pattern, on: record.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.sliderLabelWidth, alignment: .leading)
            Slider(value: value, in: range)
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.sliderReadoutWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func freqSliderRow(label: String, value: Binding<UInt16>) -> some View {
        let range = RumbleSettings.safeFrequencyRange
        let lo = Double(range.lowerBound), hi = Double(range.upperBound)
        let doubleBinding = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = UInt16($0.rounded()) }
        )
        sliderRow(
            label: label,
            value: doubleBinding,
            range: lo...hi,
            readout: String(value.wrappedValue)
        )
    }

    @ViewBuilder
    private func ampPairRow(label: String, hi: Binding<Double>, lo: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.sliderLabelWidth, alignment: .leading)
            ampMiniSlider(band: "HF", value: hi)
            ampMiniSlider(band: "LF", value: lo)
        }
    }

    @ViewBuilder
    private func ampMiniSlider(band: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(band)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

extension DeviceID: Identifiable {
    public var id: UUID { raw }
}
