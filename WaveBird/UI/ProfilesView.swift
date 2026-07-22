import SwiftUI

// The dedicated Profiles window: profile list on the left, live-editing detail on
// the right. Lives in its own window (not the Settings TabView) because a nested
// NavigationSplitView can't own the toolbar, which breaks the sidebar toggle.
struct ProfilesView: View {
    let coordinator: BridgeCoordinator

    @State private var selectedProfileID: String?
    @State private var pendingDelete: MappingProfile?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var store: MappingProfileStore { coordinator.mappingProfiles }
    private var selectedProfile: MappingProfile? {
        selectedProfileID.flatMap { store.profile(id: $0) }
    }
    private var selectedIsCustom: Bool {
        selectedProfile.map { !$0.isBuiltIn } ?? false
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, minHeight: 460)
        // Window-scoped ⌘D on the selection. A zero-opacity button registers the
        // shortcut without an app-menu command (this app's menu shortcuts are a
        // known landmine — see CLAUDE.md).
        .background {
            Button("Duplicate Profile") {
                if let profile = selectedProfile { duplicate(profile) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(selectedProfile == nil)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear { reconcileSelection() }
        .alert(
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
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Controllers using this profile revert to the default profile for its emulated controller.")
        }
    }

    private var sidebar: some View {
        List(selection: $selectedProfileID) {
            Section("Defaults") {
                ForEach(store.builtInProfiles) { row($0) }
            }
            Section("Custom") {
                ForEach(store.customProfiles) { row($0) }
            }
        }
        // .navigation lands the group just right of the sidebar toggle — a group
        // placed left of it gets split by macOS. Gated on columnVisibility so it
        // hides when the sidebar is collapsed.
        .toolbar {
            if columnVisibility != .detailOnly {
                ToolbarItemGroup(placement: .navigation) {
                    Button("New Profile", systemImage: "plus", action: addProfile)
                        .help("New Profile")
                    Button("Delete Profile", systemImage: "minus", action: deleteSelected)
                        .disabled(!selectedIsCustom)
                        .help("Delete Profile")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            ProfileDetailPane(coordinator: coordinator, profile: profile)
                .id(profile.id)
        } else {
            ContentUnavailableView("No Profile Selected", systemImage: "gamecontroller",
                                   description: Text("Select a profile from the sidebar to edit it."))
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
        .contextMenu {
            Button("Duplicate") { duplicate(profile) }
            if !profile.isBuiltIn {
                Button("Delete…", role: .destructive) { pendingDelete = profile }
            }
        }
    }

    private func duplicate(_ profile: MappingProfile) {
        selectedProfileID = store.duplicate(profile).id
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
