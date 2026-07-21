import SwiftUI

struct ProfilePickerSheet: View {
    let coordinator: BridgeCoordinator
    let deviceID: DeviceID
    @State private var selectedProfileID: String

    init(coordinator: BridgeCoordinator, deviceID: DeviceID) {
        self.coordinator = coordinator
        self.deviceID = deviceID
        // Initial selection: the device's current default-profile equivalent,
        // clamped to the allow-list so first-time setup never lands on a
        // DEBUG-only advanced mode.
        let current = coordinator.devices[deviceID]?.outputModeID
        let baseID: String = {
            if let current, HIDOutputCatalog.allowListIDs.contains(current) { return current }
            return coordinator.catalog.firstAllowListedID
        }()
        _selectedProfileID = State(initialValue: MappingProfile.defaultProfileID(forModeID: baseID))
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

            Picker("Profile", selection: $selectedProfileID) {
                ForEach(coordinator.mappingProfiles.builtInProfiles + coordinator.mappingProfiles.customProfiles) { profile in
                    let appearance = ProfileAppearance.resolve(profile)
                    Label {
                        Text(profile.name)
                    } icon: {
                        Image(systemName: appearance.symbolName)
                            .foregroundStyle(appearance.color)
                            .frame(width: 22, alignment: .center)
                    }
                    .padding(.leading, 8)
                    .tag(profile.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Button("Start") {
                Task { await coordinator.activateWithProfile(selectedProfileID, for: deviceID) }
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

}
