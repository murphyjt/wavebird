import SwiftUI

struct ProfilePickerSheet: View {
    let coordinator: BridgeCoordinator
    let deviceID: DeviceID
    @State private var selectedModeID: String
    @State private var showAdvanced = false

    init(coordinator: BridgeCoordinator, deviceID: DeviceID) {
        self.coordinator = coordinator
        self.deviceID = deviceID
        // Initial selection prefers the device's current mode if it's in the
        // user-facing allow-list; otherwise falls back to the first allow-listed
        // entry so first-time setup doesn't open with the radio group landing on
        // a hidden (advanced) mode.
        let current = coordinator.devices[deviceID]?.outputModeID
        let initial: String = {
            if let current, HIDOutputCatalog.allowListIDs.contains(current) { return current }
            return coordinator.catalog.firstAllowListedID
        }()
        _selectedModeID = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(displayName)
                    .font(.headline)
                Text("Choose how this controller appears to your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Picker("Profile", selection: $selectedModeID) {
                ForEach(coordinator.catalog.visibleEntries(showAdvanced: showAdvanced,
                                                           currentSelection: selectedModeID)) { entry in
                    Label(entry.displayName, systemImage: iconName(forOutputModeID: entry.id))
                        .tag(entry.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Button("Start") {
                Task { await coordinator.activateWithProfile(selectedModeID, for: deviceID) }
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 320)
        .optionTogglesAdvanced($showAdvanced)
    }

    private var displayName: String {
        coordinator.listEntries.first { $0.live?.id == deviceID }?.displayName ?? "Controller"
    }

    private func iconName(forOutputModeID id: String) -> String {
        switch id {
        case "xboxSeries": "xbox.logo"
        case "dualShock4", "dualSense": "playstation.logo"
        default: "gamecontroller.fill"
        }
    }
}
