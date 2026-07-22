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
    @State private var activeMappingControlID: String?

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
                if !MappingControls.nintendoLayoutSources(forModeID: draft.baseModeID).isEmpty {
                    Toggle("Use Nintendo Button Layout", isOn: Binding(
                        get: { draft.useNintendoLayout },
                        set: { draft.useNintendoLayout = $0; commit() }
                    ))
                    .disabled(isReadOnly)
                }
                ForEach(MappingControls.controls(forModeID: draft.baseModeID)) { control in
                    controlRow(control)
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

    @ViewBuilder
    private func controlLabel(_ control: OutputControl) -> some View {
        if let glyph = MappingControlSymbols.symbol(forControlID: control.id) {
            Label(control.displayName, systemImage: glyph)
        } else {
            Text(control.displayName)
        }
    }

    private func controlRow(_ control: OutputControl) -> some View {
        LabeledContent {
            Button {
                activeMappingControlID = control.id
            } label: {
                HStack(spacing: 4) {
                    Text(summary(for: control.id))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(MappingRowButtonStyle())
            .disabled(isReadOnly)
            .popover(isPresented: Binding(
                get: { activeMappingControlID == control.id },
                set: { if !$0 && activeMappingControlID == control.id { activeMappingControlID = nil } }
            )) {
                mappingOptions(for: control)
            }
        } label: {
            controlLabel(control)
        }
    }

    // Digital sources for every control; analog trigger travel is offered only
    // for analog-trigger outputs (avoids needing an analog→digital threshold).
    private func availableSources(for control: OutputControl) -> [MappingSource] {
        var sources = PhysicalButton.allCases.map { MappingSource.button($0) }
        if control.driver.isAnalogTrigger {
            sources.append(.leftAnalogTrigger)
            sources.append(.rightAnalogTrigger)
        }
        return sources
    }

    private func mappingOptions(for control: OutputControl) -> some View {
        let sources = availableSources(for: control)
        return Form {
            Section {
                optionRow("Default", isOn: isDefaultChoice(control.id)) { setDefault(control.id) }
                optionRow("Off", isOn: draft.mapping[control.id] == .off) { setOff(control.id) }
            }
            ForEach(PhysicalButton.Family.allCases) { family in
                let group = sources.filter { $0.family == family }
                if !group.isEmpty {
                    Section(family.rawValue) {
                        ForEach(group, id: \.self) { source in
                            optionRow(source.displayName, isOn: isSelected(source, control.id)) {
                                toggle(source, control.id)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 320, height: 420)
        // The popover's default vibrancy makes the list see-through against the
        // content behind it; force an opaque window-background fill.
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
    }

    private func optionRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(MappingRowButtonStyle())
    }

    private func summary(for controlID: String) -> String {
        switch draft.mapping[controlID] {
        case .none: return "Default"
        case .off: return "Off"
        case .sources(let sources):
            if sources.isEmpty { return "Default" }
            if sources.count == 1 { return sources[0].displayName }
            if sources.count <= 3 {
                return sources.map { $0.displayName.replacingOccurrences(of: " Button", with: "") }
                    .joined(separator: " + ")
            }
            return "\(sources.count) inputs"
        }
    }

    private func isDefaultChoice(_ id: String) -> Bool {
        switch draft.mapping[id] {
        case .none: return true
        case .sources(let s): return s.isEmpty
        case .off: return false
        }
    }

    private func isSelected(_ source: MappingSource, _ id: String) -> Bool {
        if case .sources(let sources) = draft.mapping[id] { return sources.contains(source) }
        return false
    }

    private func setDefault(_ id: String) { draft.mapping[id] = nil; commit() }
    private func setOff(_ id: String) { draft.mapping[id] = .off; commit() }

    private func toggle(_ source: MappingSource, _ id: String) {
        var current: [MappingSource]
        if case .sources(let sources) = draft.mapping[id] { current = sources } else { current = [] }
        if let index = current.firstIndex(of: source) {
            current.remove(at: index)
        } else {
            current.append(source)
        }
        draft.mapping[id] = current.isEmpty ? nil : .sources(current)
        commit()
    }

    // Compact stick row: [glyph] title ........ ⓘ, transforms in a popover
    // (matching the macOS Game Controllers editor) rather than an inline group.
    private func stickRow(_ title: String, systemImage: String,
                          transform: Binding<StickTransform>,
                          isPresented: Binding<Bool>) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker("", selection: transform.source) {
                    Text("Default").tag(StickSource.default)
                    Text("Left Stick").tag(StickSource.left)
                    Text("Right Stick").tag(StickSource.right)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(isReadOnly)
                .onChange(of: transform.wrappedValue.source) { commit() }

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

// A tappable full-row style that keeps the label in the primary color — .plain
// mutes it to a grey control color inside a grouped Form. Inner .tint/.secondary
// on the checkmark/chevron still win, so only the row text is forced primary.
private struct MappingRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.4 : 1)
    }
}
