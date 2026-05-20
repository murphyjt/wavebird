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

    @State private var selectedTab: Tab = .configuration
    @State private var forgetConfirmation: ForgetConfirmation?

    private enum Tab: Hashable { case configuration, about }

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
        let productID = paired?.productID ?? live?.advertisement.productID
        let settings = productID.map { coordinator.rumbleSettings(forProductID: $0) }
        let displayName = paired?.displayName ?? live?.profile.name ?? "Controller"
        let serial = paired?.serial ?? live?.serial
        let iconTint: Color = live?.virtualHID != nil
            ? (live?.firmware?.controllerType == 0x03 ? .gamecubeIndigo : .nintendoRed)
            : .secondary

        VStack(spacing: 0) {
            header(displayName: displayName, state: connectionState, tint: iconTint, paired: paired != nil)

            Picker("", selection: $selectedTab) {
                Text("Configuration").tag(Tab.configuration)
                Text("About").tag(Tab.about)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)

            Group {
                switch selectedTab {
                case .configuration:
                    configurationTab(live: live, paired: paired, settings: settings, isReady: isReady)
                case .about:
                    aboutTab(displayName: displayName, serial: serial, paired: paired, connectionState: connectionState)
                }
            }

            Divider()

            HStack {
                if let known = paired {
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
    private func configurationTab(live: DeviceRecord?, paired: KnownController?, settings: RumbleSettings?, isReady: Bool) -> some View {
        Form {
            Section {
                LabeledContent("Use profile") {
                    Picker("", selection: presentAsBinding(live: live, paired: paired)) {
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

    // Brand glyph for the "Present as" picker. Xbox/PlayStation spoofs get
    // their platform logos; Nintendo spoofs and native passthrough fall back
    // to the generic controller glyph (no Switch logo SF Symbol exists).
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
