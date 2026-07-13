import SwiftUI

// Apple-style profile editor (Name + one row per output control). Operates on
// a draft copy; Done commits through the store and notifies the coordinator so
// live controllers pick up the mapping without a republish. Built-ins open
// read-only. The base is chosen at creation only — control IDs are
// mode-prefixed, so changing base would orphan every entry.
struct ProfileEditorSheet: View {
    let coordinator: BridgeCoordinator
    let isNew: Bool
    let onDismiss: () -> Void
    @State private var draft: MappingProfile

    init(coordinator: BridgeCoordinator, profile: MappingProfile, isNew: Bool, onDismiss: @escaping () -> Void) {
        self.coordinator = coordinator
        self.isNew = isNew
        self.onDismiss = onDismiss
        _draft = State(initialValue: profile)
    }

    private var isReadOnly: Bool { draft.isBuiltIn }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .disabled(isReadOnly)
                    if isNew {
                        Picker("Emulates", selection: $draft.baseModeID) {
                            ForEach(mappableEntries) { entry in
                                Text(entry.displayName).tag(entry.id)
                            }
                        }
                        .onChange(of: draft.baseModeID) { draft.mapping = [:] }
                    } else {
                        LabeledContent("Emulates") {
                            Text(coordinator.catalog.resolved(id: draft.baseModeID).displayName)
                        }
                    }
                }
                Section {
                    ForEach(MappingControls.controls(forModeID: draft.baseModeID)) { control in
                        Picker(control.displayName, selection: choiceBinding(control.id)) {
                            Text("Default").tag("default")
                            Text("Off").tag("off")
                            ForEach(PhysicalButton.Family.allCases) { family in
                                Section(family.rawValue) {
                                    ForEach(PhysicalButton.allCases.filter { $0.family == family }) { button in
                                        Text(button.displayName).tag(button.rawValue)
                                    }
                                }
                            }
                        }
                        .disabled(isReadOnly)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(isReadOnly ? "Close" : "Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                if !isReadOnly {
                    Button("Done") {
                        coordinator.mappingProfiles.upsert(draft)
                        coordinator.mappingProfileDidChange(draft.id)
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 440, height: 540)
    }

    // Only modes with a control catalog can host a custom profile
    // (DEBUG passthrough modes bypass buildReport, so mapping can't apply).
    private var mappableEntries: [HIDOutputCatalog.Entry] {
        coordinator.catalog.entries.filter { !MappingControls.controls(forModeID: $0.id).isEmpty }
    }

    private func choiceBinding(_ controlID: String) -> Binding<String> {
        Binding(
            get: { draft.mapping[controlID]?.rawValue ?? "default" },
            set: { raw in
                if raw == "default" {
                    draft.mapping[controlID] = nil
                } else {
                    draft.mapping[controlID] = MappingChoice(rawValue: raw)
                }
            }
        )
    }
}
