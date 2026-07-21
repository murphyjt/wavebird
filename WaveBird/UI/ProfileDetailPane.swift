import SwiftUI

// Right pane of Settings → Profiles. Live-edits a draft copy; every change
// commits through the store and notifies the coordinator so running controllers
// pick up edits without a republish. Built-ins render read-only. The parent
// gives this view `.id(profile.id)` so switching selection recreates the draft.
struct ProfileDetailPane: View {
    let coordinator: BridgeCoordinator
    @State private var draft: MappingProfile
    @State private var pendingBaseChange: String?

    init(coordinator: BridgeCoordinator, profile: MappingProfile) {
        self.coordinator = coordinator
        _draft = State(initialValue: profile)
    }

    private var isReadOnly: Bool { draft.isBuiltIn }
    private var appearance: ProfileAppearance { ProfileAppearance.resolve(draft) }

    var body: some View {
        Form {
            Section {
                if isReadOnly {
                    LabeledContent("Name") { Text(draft.name) }
                } else {
                    TextField("Name", text: $draft.name)
                        .onSubmit { commit() }
                }

                LabeledContent("Symbol") {
                    ProfileSymbolPicker(symbolName: symbolBinding, tint: appearance.color)
                        .disabled(isReadOnly)
                }
                LabeledContent("Color") {
                    ProfileColorPicker(colorID: colorBinding)
                        .disabled(isReadOnly)
                }

                if isReadOnly {
                    LabeledContent("Appearance") {
                        Text(coordinator.catalog.resolved(id: draft.baseModeID).displayName)
                    }
                } else {
                    Picker("Appearance", selection: baseModeBinding) {
                        ForEach(mappableEntries) { entry in
                            Text(entry.displayName).tag(entry.id)
                        }
                    }
                }
            }

            Section("Buttons") {
                ForEach(MappingControls.controls(forModeID: draft.baseModeID)) { control in
                    Picker(selection: choiceBinding(control.id)) {
                        Text("Default").tag("default")
                        Text("Off").tag("off")
                        ForEach(PhysicalButton.Family.allCases) { family in
                            Section(family.rawValue) {
                                ForEach(PhysicalButton.allCases.filter { $0.family == family }) { button in
                                    Text(button.displayName).tag(button.rawValue)
                                }
                            }
                        }
                    } label: {
                        if let glyph = MappingControlSymbols.symbol(forControlID: control.id) {
                            Label(control.displayName, systemImage: glyph)
                        } else {
                            Text(control.displayName)
                        }
                    }
                    .disabled(isReadOnly)
                }
            }

            Section("Sticks") {
                stickControls("Left Stick", transform: $draft.leftStick)
                stickControls("Right Stick", transform: $draft.rightStick)
            }
        }
        .formStyle(.grouped)
        .onDisappear { commit() }
        .confirmationDialog(
            "Change Appearance?",
            isPresented: Binding(get: { pendingBaseChange != nil }, set: { if !$0 { pendingBaseChange = nil } })
        ) {
            Button("Change Appearance", role: .destructive) {
                if let newValue = pendingBaseChange {
                    draft.baseModeID = newValue
                    draft.mapping = [:]   // control IDs are mode-prefixed
                    commit()
                }
                pendingBaseChange = nil
            }
            Button("Cancel", role: .cancel) { pendingBaseChange = nil }
        } message: {
            Text("This profile's current button mapping will be cleared.")
        }
    }

    private var mappableEntries: [HIDOutputCatalog.Entry] {
        coordinator.catalog.entries.filter { !MappingControls.controls(forModeID: $0.id).isEmpty }
    }

    private var baseModeBinding: Binding<String> {
        Binding(
            get: { draft.baseModeID },
            set: { newValue in
                if draft.mapping.isEmpty {
                    draft.baseModeID = newValue
                    commit()
                } else {
                    pendingBaseChange = newValue
                }
            }
        )
    }

    private var symbolBinding: Binding<String> {
        Binding(
            get: { appearance.symbolName },
            set: { draft.symbolName = $0; commit() }
        )
    }

    private var colorBinding: Binding<String> {
        Binding(
            get: { draft.colorID ?? appearance.tint.rawValue },
            set: { draft.colorID = $0; commit() }
        )
    }

    private func choiceBinding(_ controlID: String) -> Binding<String> {
        Binding(
            get: { draft.mapping[controlID]?.rawValue ?? "default" },
            set: { raw in
                if raw == "default" { draft.mapping[controlID] = nil }
                else { draft.mapping[controlID] = MappingChoice(rawValue: raw) }
                commit()
            }
        )
    }

    @ViewBuilder
    private func stickControls(_ title: String, transform: Binding<StickTransform>) -> some View {
        DisclosureGroup(title) {
            Toggle("Invert Horizontally", isOn: transform.invertX)
                .onChange(of: transform.wrappedValue.invertX) { commit() }
            Toggle("Invert Vertically", isOn: transform.invertY)
                .onChange(of: transform.wrappedValue.invertY) { commit() }
            Picker("Rotate", selection: transform.rotation) {
                Text("0°").tag(StickRotation.none)
                Text("90°").tag(StickRotation.cw90)
                Text("180°").tag(StickRotation.deg180)
                Text("270°").tag(StickRotation.ccw90)
            }
            .onChange(of: transform.wrappedValue.rotation) { commit() }
        }
        .disabled(isReadOnly)
    }

    private func commit() {
        guard !isReadOnly, !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        coordinator.mappingProfiles.upsert(draft)
        coordinator.mappingProfileDidChange(draft.id)
    }
}
