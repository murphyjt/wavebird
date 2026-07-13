import SwiftUI

// Settings → Profiles: Apple Game-Controllers-style list. Defaults are
// read-only (no delete); customs open in the editor and can be deleted, with
// referencing controllers falling back to the base mode's default profile.
struct ProfilesSettingsTab: View {
    let coordinator: BridgeCoordinator

    private struct EditorState: Identifiable {
        let profile: MappingProfile
        let isNew: Bool
        var id: String { profile.id }
    }

    @State private var editor: EditorState?
    @State private var pendingDelete: MappingProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profiles configure how a controller appears to your Mac and how its buttons map. A profile can be applied to multiple controllers.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                Section("Defaults") {
                    ForEach(coordinator.mappingProfiles.builtInProfiles) { profile in
                        row(profile)
                    }
                }
                Section("Custom") {
                    ForEach(coordinator.mappingProfiles.customProfiles) { profile in
                        row(profile)
                            .contextMenu {
                                Button("Delete…", role: .destructive) { pendingDelete = profile }
                            }
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    editor = EditorState(
                        profile: MappingProfile(id: UUID().uuidString,
                                                name: "New Profile",
                                                baseModeID: coordinator.catalog.firstAllowListedID),
                        isNew: true
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Profile")
                Spacer()
            }
        }
        .padding(12)
        .sheet(item: $editor) { state in
            ProfileEditorSheet(coordinator: coordinator, profile: state.profile, isNew: state.isNew) {
                editor = nil
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDelete {
                    Task { await coordinator.deleteMappingProfile(profile.id) }
                }
                pendingDelete = nil
            }
        } message: {
            Text("Controllers using this profile revert to the default profile for its emulated controller.")
        }
    }

    @ViewBuilder
    private func row(_ profile: MappingProfile) -> some View {
        HStack {
            Image(systemName: iconName(forOutputModeID: profile.baseModeID))
                .frame(width: 22)
            VStack(alignment: .leading) {
                Text(profile.name)
                let count = coordinator.assignedControllerCount(profileID: profile.id)
                Text(count == 1 ? "1 controller" : "\(count) controllers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editor = EditorState(profile: profile, isNew: false)
        }
    }

    private func iconName(forOutputModeID id: String) -> String {
        switch id {
        case "xboxSeries": "xbox.logo"
        case "dualShock4", "dualSense": "playstation.logo"
        default: "gamecontroller.fill"
        }
    }
}
