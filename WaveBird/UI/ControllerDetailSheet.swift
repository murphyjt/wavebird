import SwiftUI

// Unified per-controller inspector. Tabs separate live tuning from static
// device info so each pane stays light. Configuration holds Present-as,
// rumble tuning, and the live rumble meter when ready. About holds device
// type / serial / last seen with a reconnect tip when offline. Forget +
// Done live in the bottom bar across both tabs.
struct ControllerDetailSheet: View {
    @Bindable var coordinator: BridgeCoordinator
    let entryID: String
    let onDismiss: () -> Void

    @State private var selectedTab: Tab = .general
    @State private var forgetConfirmation: ForgetConfirmation?

    private enum Tab: Hashable { case general, haptics, about }

    private struct ForgetConfirmation: Identifiable {
        let serial: String
        let displayName: String
        var id: String { serial }
    }

    var body: some View {
        if let entry = coordinator.listEntries.first(where: { $0.id == entryID }) {
            content(for: entry)
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear(perform: onDismiss)
        }
    }

    @ViewBuilder
    private func content(for entry: ListEntry) -> some View {
        let live = entry.live
        let paired = entry.paired
        let connectionState = live?.connectionState
        let isReady = connectionState == .ready
        let pair = coordinator.joyConPair
        let isPair = live.map { pair?.leftID == $0.id } ?? false
        let rightRecord = isPair ? pair.flatMap { coordinator.devices[$0.rightID] } : nil
        let rightPaired = rightRecord?.serial.flatMap { coordinator.knownControllers[$0] }
        let productID = paired?.productID ?? live?.advertisement.productID
        let serial = paired?.serial ?? live?.serial
        // While paired, both Joy-Con motors read from a single shared
        // RumbleSettings so the one card on screen drives both sides. Solo
        // settings are keyed by serial; productID only feeds the isGameCube flag.
        let settings = isPair
            ? coordinator.pairRumbleSettings()
            : serial.map { coordinator.rumbleSettings(forSerial: $0, productID: productID ?? 0) }
        let axis = isPair
            ? coordinator.pairAxisSettings()
            : serial.map { coordinator.axisSettings(forSerial: $0) }
        let displayName = isPair
            ? "Joy-Con 2 Pair"
            : (paired?.displayName ?? live?.profile.name ?? "Controller")
        let iconTint: Color = isPair
            ? (coordinator.joyConPairVHIDActive ? .nintendoRed : .secondary)
            : (entry.vhidActive
                ? (live?.firmware?.controllerType == 0x03 ? .gamecubeIndigo : .nintendoRed)
                : .secondary)

        VStack(spacing: 0) {
            header(displayName: displayName, state: connectionState, tint: iconTint, paired: paired != nil)

            Picker("", selection: $selectedTab) {
                Text("General").tag(Tab.general)
                Text("Haptics").tag(Tab.haptics)
                Text("About").tag(Tab.about)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)

            Group {
                switch selectedTab {
                case .general:
                    generalTab(live: live, paired: paired, axis: axis)
                case .haptics:
                    hapticsTab(live: live, settings: settings, isReady: isReady)
                case .about:
                    if isPair {
                        aboutTabForPair(
                            leftLive: live, leftPaired: paired,
                            rightLive: rightRecord, rightPaired: rightPaired,
                            connectionState: connectionState
                        )
                    } else {
                        aboutTab(displayName: displayName, serial: serial, paired: paired, connectionState: connectionState)
                    }
                }
            }

            Divider()

            HStack {
                if isPair {
                    Button("Split Paired Controllers", role: .destructive) {
                        Task {
                            await coordinator.splitJoyConPair()
                            onDismiss()
                        }
                    }
                    .help("Tears down the merged Joy-Con virtual device. Both Joy-Cons stay connected but won't auto-pair again this session.")
                } else if let known = paired {
                    Button("Forget This Device…", role: .destructive) {
                        forgetConfirmation = ForgetConfirmation(serial: known.serial, displayName: displayName)
                    }
                    .help(known.isPaired
                          ? "Removes WaveBird's record of this pairing and its saved profile. The controller keeps its stored key until you pair it with something else."
                          : "Removes this controller's saved profile. You'll be asked again the next time it connects.")
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .sheet(item: $forgetConfirmation) { confirm in
            ForgetConfirmationSheet(
                displayName: confirm.displayName,
                onForget: {
                    let serial = confirm.serial
                    forgetConfirmation = nil
                    // Defer window dismiss so SwiftUI can finish dismissing the
                    // confirmation sheet first; calling dismissWindow while a
                    // child sheet is still animating leaves the window open.
                    Task { @MainActor in
                        await coordinator.forgetController(serial: serial)
                        onDismiss()
                    }
                },
                onCancel: {
                    forgetConfirmation = nil
                }
            )
        }
    }

    @ViewBuilder
    private func generalTab(live: DeviceRecord?, paired: KnownController?, axis: AxisSettings?) -> some View {
        let binding = presentAsBinding(live: live, paired: paired)
        Form {
            Section {
                LabeledContent("Use profile") {
                    Picker("", selection: binding) {
                        ForEach(coordinator.catalog.entries) { entry in
                            Label(entry.displayName, systemImage: Self.iconName(forOutputModeID: entry.id))
                                .tag(entry.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            if let axis {
                StickSettingsSection(settings: axis)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func hapticsTab(live: DeviceRecord?, settings: RumbleSettings?, isReady: Bool) -> some View {
        Form {
            if let settings {
                RumbleSettingsCard(coordinator: coordinator, liveDeviceID: isReady ? live?.id : nil, settings: settings)
            }
        }
        .formStyle(.grouped)
        // Animate Test-row insert/remove when readiness flips (e.g., controller
        // becomes .ready or drops). Intensity-driven show/hide is animated via
        // the slider's withAnimation binding inside the card.
        .animation(.easeInOut(duration: 0.25), value: isReady)
    }

    @ViewBuilder
    private func aboutTab(displayName: String, serial: String?, paired: KnownController?, connectionState: DeviceConnectionState?) -> some View {
        Form {
            Section {
                LabeledContent("Device Type") {
                    Text(displayName)
                }
                if let serial {
                    LabeledContent("Serial Number") {
                        Text(serial)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
                if let paired, paired.lastSeenAt > .distantPast {
                    LabeledContent("Last Connected",
                                   value: Self.formatLastConnected(paired.lastSeenAt))
                }
            } footer: {
                if connectionState != .ready {
                    Text("Press any button on the controller to reconnect. If it's not advertising, hold SYNC to wake it up.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // Pair variant: one Section per side so the user can see each Joy-Con's
    // own serial and last-connected timestamp. The merged identity ("Joy-Con
    // 2 Pair") lives in the header above; the per-side rows here
    // surface info specific to each physical Joy-Con.
    @ViewBuilder
    private func aboutTabForPair(
        leftLive: DeviceRecord?, leftPaired: KnownController?,
        rightLive: DeviceRecord?, rightPaired: KnownController?,
        connectionState: DeviceConnectionState?
    ) -> some View {
        Form {
            joyConAboutSection(
                title: "Left Joy-Con",
                live: leftLive,
                paired: leftPaired
            )
            joyConAboutSection(
                title: "Right Joy-Con",
                live: rightLive,
                paired: rightPaired
            )
            if connectionState != .ready {
                Section {
                    Text("Press any button on the controller to reconnect. If it's not advertising, hold SYNC to wake it up.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func joyConAboutSection(title: String, live: DeviceRecord?, paired: KnownController?) -> some View {
        let name = paired?.displayName ?? live?.profile.name ?? title
        let serial = paired?.serial ?? live?.serial
        Section(title) {
            LabeledContent("Device Type") {
                Text(name)
            }
            if let serial {
                LabeledContent("Serial Number") {
                    Text(serial)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
            if let paired, paired.lastSeenAt > .distantPast {
                LabeledContent("Last Connected",
                               value: Self.formatLastConnected(paired.lastSeenAt))
            }
        }
    }

    @ViewBuilder
    private func header(displayName: String, state: DeviceConnectionState?, tint: Color, paired: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.stateColor(state))
                        .frame(width: 8, height: 8)
                    Text(Self.stateLabel(state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
    }

    // Present-as picker binding. Writes to the live record (republishes the
    // virtual HID) and persists the per-serial preference so the choice
    // survives disconnects. Reads prefer live → paired preference → global default.
    private func presentAsBinding(live: DeviceRecord?, paired: KnownController?) -> Binding<String> {
        Binding(
            get: {
                live?.outputModeID
                    ?? paired?.preferredOutputModeID
                    ?? coordinator.defaultOutputModeID
            },
            set: { id in
                if let liveID = live?.id {
                    Task { await coordinator.setOutputMode(id, for: liveID) }
                }
                if let serial = paired?.serial ?? live?.serial {
                    Task { await coordinator.setPreferredOutputMode(id, forSerial: serial) }
                }
            }
        )
    }

    private static func iconName(forOutputModeID id: String) -> String {
        switch id {
        case "xboxSeries":             "xbox.logo"
        case "dualShock4", "dualSense": "playstation.logo"
        default:                       "gamecontroller.fill"
        }
    }

    private static func stateLabel(_ s: DeviceConnectionState?) -> String {
        switch s {
        case .discovered: "Discovered"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .ready: "Ready"
        case .disconnected, nil: "Not Connected"
        case .failed(let msg): "Failed: \(msg)"
        }
    }

    private static func stateColor(_ s: DeviceConnectionState?) -> Color {
        switch s {
        case .connected, .ready: .green
        case .connecting, .discovered: .orange
        case .disconnected, .failed, nil: .red
        }
    }

    // Granularity: minute under an hour, hour under a day, day after that.
    // RelativeDateTimeFormatter auto-picks units; we want explicit buckets so
    // the readout doesn't jump between "1 minute" and "60 seconds" near edges.
    static func formatLastConnected(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 60 { return "Just now" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        var components = DateComponents()
        if elapsed < 3600 {
            components.minute = -Int(elapsed / 60)
        } else if elapsed < 86400 {
            components.hour = -Int(elapsed / 3600)
        } else {
            components.day = -Int(elapsed / 86400)
        }
        return formatter.localizedString(from: components)
    }
}

// Stick configuration: per-axis Y inversion. Bound to the per-PID AxisSettings,
// so toggling takes effect live on the running dispatch task and persists.
private struct StickSettingsSection: View {
    @Bindable var settings: AxisSettings

    var body: some View {
        Section("Sticks") {
            Toggle("Invert Left Stick Y-Axis", isOn: $settings.invertLeftY)
            Toggle("Invert Right Stick Y-Axis", isOn: $settings.invertRightY)
        }
    }
}
