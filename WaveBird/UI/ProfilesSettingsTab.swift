import SwiftUI

// Settings → Profiles, Safari-style: selectable profile list on the left,
// live-editing detail on the right. Defaults are read-only and undeletable;
// customs are editable and deletable (referencing controllers fall back to the
// base mode's default profile).
struct ProfilesSettingsTab: View {
    let coordinator: BridgeCoordinator

    @State private var selectedProfileID: String?
    @State private var pendingDelete: MappingProfile?

    private var store: MappingProfileStore { coordinator.mappingProfiles }
    private var selectedProfile: MappingProfile? {
        selectedProfileID.flatMap { store.profile(id: $0) }
    }
    private var selectedIsCustom: Bool {
        selectedProfile.map { !$0.isBuiltIn } ?? false
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { reconcileSelection() }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let victim = pendingDelete {
                    Task {
                        await coordinator.deleteMappingProfile(victim.id)
                        if selectedProfileID == victim.id { selectedProfileID = nil }
                        reconcileSelection()
                    }
                }
                pendingDelete = nil
            }
        } message: {
            Text("Controllers using this profile revert to the default profile for its emulated controller.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedProfileID) {
                Section("Defaults") {
                    ForEach(store.builtInProfiles) { row($0) }
                }
                Section("Custom") {
                    ForEach(store.customProfiles) { profile in
                        row(profile)
                            .contextMenu {
                                Button("Delete…", role: .destructive) { pendingDelete = profile }
                            }
                    }
                }
            }

            Divider()
            HStack(spacing: 0) {
                Button(action: addProfile) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 22)
                    .help("New Profile")
                Divider().frame(height: 14)
                Button(action: deleteSelected) { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 22)
                    .disabled(!selectedIsCustom)
                    .help("Delete Profile")
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            ProfileDetailPane(coordinator: coordinator, profile: profile)
                .id(profile.id)
        } else {
            Text("Select a profile")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ profile: MappingProfile) -> some View {
        let appearance = ProfileAppearance.resolve(profile)
        let count = coordinator.assignedControllerCount(profileID: profile.id)
        return HStack {
            Image(systemName: appearance.symbolName)
                .foregroundStyle(appearance.color)
                .frame(width: 22)
            VStack(alignment: .leading) {
                Text(profile.name)
                Text(count == 1 ? "1 controller" : "\(count) controllers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(profile.id)
    }

    private func addProfile() {
        let new = MappingProfile(id: UUID().uuidString,
                                 name: "New Profile",
                                 baseModeID: coordinator.catalog.firstAllowListedID)
        store.upsert(new)
        selectedProfileID = new.id
    }

    private func deleteSelected() {
        pendingDelete = selectedProfile.flatMap { $0.isBuiltIn ? nil : $0 }
    }

    // Keep selection pointing at a real profile after add/delete/first show.
    private func reconcileSelection() {
        if let id = selectedProfileID, store.profile(id: id) != nil { return }
        selectedProfileID = store.builtInProfiles.first?.id
    }
}
