import SwiftUI

// Right pane of Settings → Profiles. Live-edits a draft copy; every change
// commits through the store and notifies the coordinator so running controllers
// pick up edits without a republish. Built-ins render read-only. The parent
// gives this view `.id(profile.id)` so switching selection recreates the draft.
struct ProfileDetailPane: View {
    let coordinator: BridgeCoordinator
    @State private var draft: MappingProfile
    @State private var pendingBaseChange: String?
    @State private var showLeftStickOptions = false
    @State private var showRightStickOptions = false

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

                stickRow("Left Stick", systemImage: "l.joystick",
                         transform: $draft.leftStick, isPresented: $showLeftStickOptions)
                stickRow("Right Stick", systemImage: "r.joystick",
                         transform: $draft.rightStick, isPresented: $showRightStickOptions)
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
                if newValue == draft.baseModeID {
                    return
                } else if draft.mapping.isEmpty {
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
            get: {
                switch draft.mapping[controlID] {
                case .none: "default"
                case .off: "off"
                case .sources(let sources): sources.first?.token ?? "default"
                }
            },
            set: { raw in
                switch raw {
                case "default": draft.mapping[controlID] = nil
                case "off": draft.mapping[controlID] = .off
                default:
                    if let source = MappingSource(token: raw) {
                        draft.mapping[controlID] = .sources([source])
                    }
                }
                commit()
            }
        )
    }

    // Compact stick row: [glyph] title ........ ⓘ, transforms in a popover
    // (matching the macOS Game Controllers editor) rather than an inline group.
    private func stickRow(_ title: String, systemImage: String,
                          transform: Binding<StickTransform>,
                          isPresented: Binding<Bool>) -> some View {
        LabeledContent {
            Button { isPresented.wrappedValue = true } label: {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isReadOnly)
            .popover(isPresented: isPresented, arrowEdge: .trailing) {
                stickOptions(transform)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func stickOptions(_ transform: Binding<StickTransform>) -> some View {
        Form {
            Toggle(isOn: transform.invertX) {
                Label("Invert Horizontally", systemImage: "arrow.left.and.right.circle")
            }
            .onChange(of: transform.wrappedValue.invertX) { commit() }
            Toggle(isOn: transform.invertY) {
                Label("Invert Vertically", systemImage: "arrow.up.and.down.circle")
            }
            .onChange(of: transform.wrappedValue.invertY) { commit() }
            Picker(selection: transform.rotation) {
                Text("None").tag(StickRotation.none)
                Text("Left").tag(StickRotation.ccw90)
                Text("Right").tag(StickRotation.cw90)
            } label: {
                Label("Rotate Input", systemImage: "arrow.clockwise.circle")
            }
            .onChange(of: transform.wrappedValue.rotation) { commit() }
        }
        .formStyle(.grouped)
        .frame(width: 320, height: 134)
    }

    private func commit() {
        guard !isReadOnly, !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Don't let an onDisappear flush resurrect a profile deleted out from under us.
        guard coordinator.mappingProfiles.profile(id: draft.id) != nil else { return }
        coordinator.mappingProfiles.upsert(draft)
        coordinator.mappingProfileDidChange(draft.id)
    }
}
