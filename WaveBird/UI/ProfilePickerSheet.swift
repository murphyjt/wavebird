import SwiftUI

struct ProfilePickerSheet: View {
    let coordinator: BridgeCoordinator
    let deviceID: DeviceID
    @State private var selectedModeID: String

    init(coordinator: BridgeCoordinator, deviceID: DeviceID) {
        self.coordinator = coordinator
        self.deviceID = deviceID
        _selectedModeID = State(initialValue: coordinator.devices[deviceID]?.outputModeID ?? HIDOutputCatalog.nativeID)
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
                ForEach(coordinator.catalog.entries) { entry in
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
