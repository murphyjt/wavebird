import SwiftUI

struct RumbleSettingsCard: View {
    let coordinator: BridgeCoordinator
    // Only set when the device is actually .ready — the Test row keys off this
    // so it disappears whenever the controller isn't usable. Offline rows still
    // get tuning controls (presets/freq/amp) but no test buttons.
    let liveDeviceID: DeviceID?
    @Bindable var settings: RumbleSettings

    @ViewBuilder
    var body: some View {
        Section {
            LabeledContent("Haptic Feedback") {
                VStack(spacing: 2) {
                    // GC: two positions (off/on). Pro: five stops at 0/25/50/75/100%.
                    // Binding wraps the setter in withAnimation so the Test row
                    // fades when the slider crosses the off/on threshold.
                    Slider(
                        value: intensityBinding,
                        in: 0...1,
                        step: settings.isGameCube ? 1 : 0.25
                    )
                    HStack {
                        Text("off")
                        Spacer()
                        Text(settings.isGameCube ? "on" : "strong")
                    }
                    .font(.caption)
                    .foregroundStyle(.primary)
                }
            }
            if let liveDeviceID, settings.intensity > 0 {
                LabeledContent("Test") {
                    HStack(spacing: 6) {
                        ForEach(testPatterns) { pattern in
                            Button(testButtonLabel(for: pattern)) {
                                coordinator.playTestRumble(pattern, on: liveDeviceID)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        if !settings.isGameCube {
            Section {
                LabeledContent("Haptic Preset") {
                    Picker("", selection: $settings.preset) {
                        ForEach(RumbleSettings.Preset.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                freqRow("Left Frequency",  value: $settings.leftHiFreq)
                freqRow("Right Frequency", value: $settings.rightHiFreq)
                ampRow("Left HF Amplitude",  value: $settings.leftHiAmpScale)
                ampRow("Left LF Amplitude",  value: $settings.leftLoAmpScale)
                ampRow("Right HF Amplitude", value: $settings.rightHiAmpScale)
                ampRow("Right LF Amplitude", value: $settings.rightLoAmpScale)
            }
        }
    }

    // Wrap intensity writes in an animation transaction so the Test row's
    // appearance/removal at the off/on boundary glides in/out.
    private var intensityBinding: Binding<Double> {
        Binding(
            get: { settings.intensity },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.25)) {
                    settings.intensity = newValue
                }
            }
        )
    }

    // GC's encodeRumble is on/off, so only "On" (the .both pattern fires the
    // single motor) and "Alternate" produce distinct behavior; the others all
    // collapse to a brief blip and are hidden.
    private var testPatterns: [TestRumblePattern] {
        settings.isGameCube ? [.both, .alternate] : TestRumblePattern.allCases
    }

    private func testButtonLabel(for pattern: TestRumblePattern) -> String {
        if settings.isGameCube && pattern == .both { return "On" }
        return pattern.label
    }

    @ViewBuilder
    private func freqRow(_ label: String, value: Binding<UInt16>) -> some View {
        let range = RumbleSettings.safeFrequencyRange
        let lo = Double(range.lowerBound), hi = Double(range.upperBound)
        let doubleBinding = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = UInt16($0.rounded()) }
        )
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: doubleBinding, in: lo...hi)
                Text(String(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func ampRow(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: 0...1)
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}
