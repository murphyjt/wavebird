# Profiles Editor Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the modal Profiles editor with a Safari-style master/detail editor, give profiles a tinted symbol identity, symbol-ify the mapping rows, and add per-stick transforms that fold in and retire the per-serial Y-axis inversion.

**Architecture:** Phase 1 is pure UI + cosmetic metadata and keeps the input pipeline byte-identical. Phase 2 adds stick transforms that ride the existing per-report `MappingSpecBox` (so no new per-device plumbing) and retires `AxisSettings`. New profile fields are optional/defaulted so old JSON blobs still decode.

**Tech Stack:** Swift 6.2 (strict concurrency, `nonisolated` default), SwiftUI, Swift Testing, CoreHID/CoreBluetooth (untouched here).

## Global Constraints

- New persisted profile fields MUST be optional or defaulted; a missing key must never fail decode (per CLAUDE.md persistence rule).
- Reuse the existing `MappingSpecBox` / `OSAllocatedUnfairLock<Snapshot>` idiom; introduce no new synchronization style.
- Phase 1 keeps the input pipeline byte-identical (no hardware pass needed). Phase 2 (Tasks 7–10) changes input bytes and needs a hardware validation pass; it is committed separately.
- `MappingChoice`/`PhysicalButton` raw values are persistence format — never rename.
- SF Symbol names that don't exist render blank; only ship names known to exist. Where none fits, fall back to text (no glyph).
- Commit messages: short title (≤72 chars), 2–4 line body. End with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Build command:
  `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
- Test command:
  `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`

---

## PHASE 1 — Pure UI / cosmetic (pipeline byte-identical)

### Task 1: ProfileColor palette

**Files:**
- Create: `WaveBird/Profiles/ProfileColor.swift`
- Test: `WaveBirdTests/ProfileAppearanceTests.swift`

**Interfaces:**
- Produces: `enum ProfileColor: String, CaseIterable, Sendable, Identifiable` with `var id: String`, `var color: Color`, and `static let automatic: ProfileColor` (== `.automatic` case). `colorID` strings persist as `rawValue`.

- [ ] **Step 1: Write the failing test**

Create `WaveBirdTests/ProfileAppearanceTests.swift`:

```swift
import Foundation
import Testing
@testable import WaveBird

struct ProfileColorTests {
    @Test func rawValuesRoundTrip() {
        for color in ProfileColor.allCases {
            #expect(ProfileColor(rawValue: color.rawValue) == color)
        }
    }

    @Test func automaticIsFirstAndPaletteIsUniqueSixteen() {
        #expect(ProfileColor.allCases.first == .automatic)
        #expect(ProfileColor.allCases.count == 16)
        let raws = ProfileColor.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
    }

    @Test func unknownRawValueIsNil() {
        #expect(ProfileColor(rawValue: "chartreuse-glow") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/ProfileColorTests`
Expected: FAIL — `cannot find 'ProfileColor' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `WaveBird/Profiles/ProfileColor.swift`:

```swift
import SwiftUI

// Named tint swatches for profile symbols. Stored by name (rawValue) so the
// palette stays stable and theme-aware across releases rather than baking RGB.
// `.automatic` (first swatch) means "no explicit tint" — resolves to the accent.
enum ProfileColor: String, CaseIterable, Sendable, Identifiable {
    case automatic
    case red, orange, yellow, green, mint, teal, cyan
    case blue, indigo, purple, pink, brown, gray, lime, slate

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .automatic: .accentColor
        case .red:       .red
        case .orange:    .orange
        case .yellow:    .yellow
        case .green:     .green
        case .mint:      .mint
        case .teal:      .teal
        case .cyan:      .cyan
        case .blue:      .blue
        case .indigo:    .indigo
        case .purple:    .purple
        case .pink:      .pink
        case .brown:     .brown
        case .gray:      .gray
        case .lime:      Color(red: 0.68, green: 0.82, blue: 0.36)
        case .slate:     Color(red: 0.44, green: 0.50, blue: 0.56)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/ProfileColorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Profiles/ProfileColor.swift WaveBirdTests/ProfileAppearanceTests.swift
git commit -m "feat: add ProfileColor palette

16 named tint swatches (automatic + 15), stored by name so profile
symbol colors stay theme-aware and stable across releases.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: ProfileSymbol list + per-base default appearance

**Files:**
- Create: `WaveBird/Profiles/ProfileSymbol.swift`
- Test: `WaveBirdTests/ProfileAppearanceTests.swift:<append>`

**Interfaces:**
- Consumes: `ProfileColor` (Task 1).
- Produces: `enum ProfileSymbol` with `static let quick: [String]`, `static let all: [String]` (quick ⊆ all), and `static func defaultAppearance(forBaseModeID: String) -> (symbol: String, color: ProfileColor)`.

- [ ] **Step 1: Write the failing test**

Append to `WaveBirdTests/ProfileAppearanceTests.swift`:

```swift
struct ProfileSymbolTests {
    @Test func quickIsSubsetOfAllAndUnique() {
        #expect(Set(ProfileSymbol.quick).isSubset(of: Set(ProfileSymbol.all)))
        #expect(Set(ProfileSymbol.all).count == ProfileSymbol.all.count)
    }

    @Test func defaultsCoverShippingBaseModes() {
        #expect(ProfileSymbol.defaultAppearance(forBaseModeID: "xboxSeries").color == .green)
        #expect(ProfileSymbol.defaultAppearance(forBaseModeID: "dualShock4").symbol == "playstation.logo")
        #expect(ProfileSymbol.defaultAppearance(forBaseModeID: "dualSense").symbol == "playstation.logo")
        #expect(ProfileSymbol.defaultAppearance(forBaseModeID: "switchPro").color == .red)
        // Unknown base mode still yields a usable fallback, never crashes.
        #expect(!ProfileSymbol.defaultAppearance(forBaseModeID: "mystery").symbol.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/ProfileSymbolTests`
Expected: FAIL — `cannot find 'ProfileSymbol' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `WaveBird/Profiles/ProfileSymbol.swift`:

```swift
import Foundation

// Curated, extensible SF Symbol set for profile identity. `quick` is the inline
// row (controller brands); `all` is what the "more" popover shows. Add names to
// `more` to extend the picker — no picker-code change needed. All names are
// known to exist in SF Symbols; unknown names would render blank.
enum ProfileSymbol {
    static let quick: [String] = [
        "xbox.logo",
        "playstation.logo",
        "gamecontroller.fill",
        "formfitting.gamecontroller.fill",
    ]

    static let more: [String] = [
        "l.joystick.press.down.fill",
        "dpad.fill",
        "arcade.stick",
        "arcade.stick.console.fill",
        "headphones",
        "bolt.fill",
        "star.fill",
        "flag.fill",
        "trophy.fill",
        "target",
        "circle.hexagongrid.fill",
        "flame.fill",
    ]

    static var all: [String] { quick + more }

    // Default symbol + tint synthesized for a profile that hasn't chosen its own
    // (built-ins never store appearance; customs fall back to their base mode's).
    static func defaultAppearance(forBaseModeID id: String) -> (symbol: String, color: ProfileColor) {
        switch id {
        case "xboxSeries":            ("xbox.logo", .green)
        case "dualShock4", "dualSense": ("playstation.logo", .blue)
        case "switchPro":             ("gamecontroller.fill", .red)
        default:                      ("gamecontroller.fill", .gray)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/ProfileSymbolTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Profiles/ProfileSymbol.swift WaveBirdTests/ProfileAppearanceTests.swift
git commit -m "feat: add ProfileSymbol curated set and base defaults

Quick brand row + extensible 'more' list, plus per-base-mode default
symbol/color synthesis for profiles without a chosen appearance.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: MappingProfile appearance fields + resolver

**Files:**
- Modify: `WaveBird/Profiles/MappingProfile.swift:7-20`
- Create: `WaveBird/Profiles/ProfileAppearance.swift`
- Test: `WaveBirdTests/ProfileAppearanceTests.swift:<append>`

**Interfaces:**
- Consumes: `ProfileSymbol`, `ProfileColor`.
- Produces: `MappingProfile.symbolName: String?`, `MappingProfile.colorID: String?` (both default `nil`, memberwise init gains trailing defaulted params). `struct ProfileAppearance { let symbolName: String; let tint: ProfileColor; var color: Color { tint.color } ; static func resolve(_ profile: MappingProfile) -> ProfileAppearance }`.

- [ ] **Step 1: Write the failing test**

Append to `WaveBirdTests/ProfileAppearanceTests.swift`:

```swift
struct ProfileAppearanceResolveTests {
    @Test func oldBlobWithoutAppearanceDecodesToNil() throws {
        // A pre-appearance custom-profile blob has no symbolName/colorID keys.
        let json = """
        {"id":"abc","name":"Legacy","baseModeID":"xboxSeries","mapping":{}}
        """
        let profile = try JSONDecoder().decode(MappingProfile.self, from: Data(json.utf8))
        #expect(profile.symbolName == nil)
        #expect(profile.colorID == nil)
    }

    @Test func resolveFallsBackToBaseDefault() {
        let bare = MappingProfile(id: "x", name: "Bare", baseModeID: "xboxSeries")
        let a = ProfileAppearance.resolve(bare)
        #expect(a.symbolName == "xbox.logo")
        #expect(a.tint == .green)
    }

    @Test func resolveHonorsExplicitChoice() {
        let custom = MappingProfile(id: "y", name: "Mine", baseModeID: "switchPro",
                                    symbolName: "flame.fill", colorID: "purple")
        let a = ProfileAppearance.resolve(custom)
        #expect(a.symbolName == "flame.fill")
        #expect(a.tint == .purple)
    }

    @Test func resolveIgnoresUnknownColorID() {
        let custom = MappingProfile(id: "z", name: "Bad", baseModeID: "switchPro", colorID: "not-a-color")
        #expect(ProfileAppearance.resolve(custom).tint == .red)  // base default
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/ProfileAppearanceResolveTests`
Expected: FAIL — `extra arguments 'symbolName', 'colorID'` / `cannot find 'ProfileAppearance'`.

- [ ] **Step 3: Write minimal implementation**

Edit `WaveBird/Profiles/MappingProfile.swift` — add the two stored properties to the struct (after `mapping`):

```swift
struct MappingProfile: Codable, Sendable, Hashable, Identifiable {
    var id: String            // "default.<modeID>" for built-ins; UUID string for customs
    var name: String
    var baseModeID: String    // HIDOutputCatalog entry ID; fixed after creation
    var mapping: [String: MappingChoice] = [:]
    var symbolName: String? = nil   // nil → synthesize from base mode
    var colorID: String? = nil      // ProfileColor rawValue; nil/unknown → base default

    static let defaultIDPrefix = "default."

    static func defaultProfileID(forModeID modeID: String) -> String {
        defaultIDPrefix + modeID
    }

    var isBuiltIn: Bool { id.hasPrefix(Self.defaultIDPrefix) }
}
```

(Both new properties are `Optional`, so the synthesized `Decodable` already treats a missing key as `nil` — no custom init needed at this task.)

Create `WaveBird/Profiles/ProfileAppearance.swift`:

```swift
import SwiftUI

// Effective symbol + tint for a profile: its explicit choice if set, otherwise
// the synthesized default for its base mode. One resolver used by the Settings
// list, the detail pane, and the "Use profile" pickers so identity is uniform.
struct ProfileAppearance {
    let symbolName: String
    let tint: ProfileColor
    var color: Color { tint.color }

    static func resolve(_ profile: MappingProfile) -> ProfileAppearance {
        let base = ProfileSymbol.defaultAppearance(forBaseModeID: profile.baseModeID)
        let symbol = profile.symbolName ?? base.symbol
        let tint = profile.colorID.flatMap(ProfileColor.init(rawValue:)) ?? base.color
        return ProfileAppearance(symbolName: symbol, tint: tint)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/ProfileAppearanceResolveTests`
Expected: PASS. Also run the full suite to confirm existing `MappingProfileTests` (JSON round-trip, store) still pass:
Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Profiles/MappingProfile.swift WaveBird/Profiles/ProfileAppearance.swift WaveBirdTests/ProfileAppearanceTests.swift
git commit -m "feat: add symbol/color to MappingProfile with resolver

Optional symbolName/colorID (old blobs decode to nil) plus a
ProfileAppearance resolver that falls back to per-base-mode defaults.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Master/detail Profiles editor

**Files:**
- Rewrite: `WaveBird/UI/ProfilesSettingsTab.swift`
- Create: `WaveBird/UI/ProfileDetailPane.swift`
- Create: `WaveBird/UI/ProfileAppearancePickers.swift`
- Delete: `WaveBird/UI/ProfileEditorSheet.swift`

**Interfaces:**
- Consumes: `coordinator.mappingProfiles` (`.builtInProfiles`, `.customProfiles`, `.upsert`), `coordinator.mappingProfileDidChange(_:)`, `coordinator.deleteMappingProfile(_:)`, `coordinator.assignedControllerCount(profileID:)`, `coordinator.catalog`, `ProfileAppearance.resolve`, `ProfileSymbol`, `ProfileColor`.
- Produces: two-pane `ProfilesSettingsTab`; `ProfileDetailPane` (edits a draft, live-commits); `ProfileSymbolPicker` + `ProfileColorPicker` popover views.

- [ ] **Step 1: Delete the obsolete modal editor**

```bash
git rm WaveBird/UI/ProfileEditorSheet.swift
```

- [ ] **Step 2: Create the appearance pickers**

Create `WaveBird/UI/ProfileAppearancePickers.swift`:

```swift
import SwiftUI

// Symbol picker: a quick brand row + an ellipsis that opens the fuller grid.
struct ProfileSymbolPicker: View {
    @Binding var symbolName: String
    let tint: Color
    @State private var showMore = false

    private let cell: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProfileSymbol.quick, id: \.self) { name in
                swatch(name)
            }
            Button {
                showMore = true
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: cell, height: cell)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(Color.secondary.opacity(0.15)))
            .popover(isPresented: $showMore, arrowEdge: .bottom) {
                grid
                    .padding(12)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell + 6), spacing: 10), count: 6), spacing: 10) {
            ForEach(ProfileSymbol.all, id: \.self) { name in
                Button {
                    symbolName = name
                    showMore = false
                } label: {
                    Image(systemName: name)
                        .frame(width: cell, height: cell)
                        .foregroundStyle(name == symbolName ? tint : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 6 * (cell + 16))
    }

    private func swatch(_ name: String) -> some View {
        Button {
            symbolName = name
        } label: {
            Image(systemName: name)
                .foregroundStyle(name == symbolName ? tint : .primary)
                .frame(width: cell, height: cell)
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(Circle().strokeBorder(name == symbolName ? tint : .clear, lineWidth: 2))
        )
    }
}

// Color picker: a single tinted pill that opens a swatch grid popover.
struct ProfileColorPicker: View {
    @Binding var colorID: String
    @State private var showPalette = false

    private var selected: ProfileColor { ProfileColor(rawValue: colorID) ?? .automatic }

    var body: some View {
        Button {
            showPalette = true
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected.color)
                .frame(width: 42, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPalette, arrowEdge: .bottom) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 12), count: 4), spacing: 12) {
                ForEach(ProfileColor.allCases) { swatch in
                    Button {
                        colorID = swatch.rawValue
                        showPalette = false
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(swatch == selected ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }
}
```

- [ ] **Step 3: Create the detail pane**

Create `WaveBird/UI/ProfileDetailPane.swift`:

```swift
import SwiftUI

// Right pane of Settings → Profiles. Live-edits a draft copy; every change
// commits through the store and notifies the coordinator so running controllers
// pick up edits without a republish. Built-ins render read-only. The parent
// gives this view `.id(profile.id)` so switching selection recreates the draft.
struct ProfileDetailPane: View {
    let coordinator: BridgeCoordinator
    @State private var draft: MappingProfile

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
                        .onChange(of: draft.name) { commit() }
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
                    LabeledContent("Emulates") {
                        Text(coordinator.catalog.resolved(id: draft.baseModeID).displayName)
                    }
                } else {
                    Picker("Emulates", selection: $draft.baseModeID) {
                        ForEach(mappableEntries) { entry in
                            Text(entry.displayName).tag(entry.id)
                        }
                    }
                    .onChange(of: draft.baseModeID) {
                        draft.mapping = [:]   // control IDs are mode-prefixed
                        commit()
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
                        Text(control.displayName)
                    }
                    .disabled(isReadOnly)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var mappableEntries: [HIDOutputCatalog.Entry] {
        coordinator.catalog.entries.filter { !MappingControls.controls(forModeID: $0.id).isEmpty }
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

    private func commit() {
        guard !isReadOnly, !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        coordinator.mappingProfiles.upsert(draft)
        coordinator.mappingProfileDidChange(draft.id)
    }
}
```

- [ ] **Step 4: Rewrite the tab as master/detail**

Replace the entire contents of `WaveBird/UI/ProfilesSettingsTab.swift`:

```swift
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
                        await MainActor.run {
                            if selectedProfileID == victim.id { selectedProfileID = nil }
                            reconcileSelection()
                        }
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
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. Fix any compile errors (most likely: `HIDOutputCatalog.Entry` member names, `catalog.resolved(id:)` — cross-check against `WaveBird/HID/HIDOutputProfile.swift`).

- [ ] **Step 6: Commit**

```bash
git add WaveBird/UI/ProfilesSettingsTab.swift WaveBird/UI/ProfileDetailPane.swift WaveBird/UI/ProfileAppearancePickers.swift
git commit -m "feat: master/detail Profiles editor with symbol+color

Replace the modal editor with a Safari-style selectable list + live
detail pane; add symbol and color pickers. Delete ProfileEditorSheet.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Symbol-ified mapping rows

**Files:**
- Create: `WaveBird/UI/MappingControlSymbols.swift`
- Modify: `WaveBird/UI/ProfileDetailPane.swift` (the `Buttons` section `Picker` label)
- Test: `WaveBirdTests/ProfileAppearanceTests.swift:<append>`

**Interfaces:**
- Produces: `enum MappingControlSymbols { static func symbol(forControlID: String) -> String? }` — an SF Symbol name for the emulated control, or `nil` (text-only fallback).

- [ ] **Step 1: Write the failing test**

Append to `WaveBirdTests/ProfileAppearanceTests.swift`:

```swift
struct MappingControlSymbolsTests {
    @Test func faceButtonsMapToGlyphs() {
        #expect(MappingControlSymbols.symbol(forControlID: "xboxSeries.a") == "a.circle")
        #expect(MappingControlSymbols.symbol(forControlID: "switchPro.y") == "y.circle")
        #expect(MappingControlSymbols.symbol(forControlID: "dualShock4.cross") == "xmark")
        #expect(MappingControlSymbols.symbol(forControlID: "dualSense.triangle") == "triangle")
    }

    @Test func unmappedControlFallsBackToNil() {
        #expect(MappingControlSymbols.symbol(forControlID: "xboxSeries.leftTrigger") == nil)
        #expect(MappingControlSymbols.symbol(forControlID: "whatever.zzz") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/MappingControlSymbolsTests`
Expected: FAIL — `cannot find 'MappingControlSymbols' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `WaveBird/UI/MappingControlSymbols.swift`:

```swift
import Foundation

// SF Symbol glyph for an emulated control row, keyed by the control ID's suffix
// (the token after the mode prefix). Only names known to exist in SF Symbols are
// returned; anything without a faithful glyph returns nil so the row stays
// text-only (the glyph is an accent, never the sole signifier).
enum MappingControlSymbols {
    static func symbol(forControlID id: String) -> String? {
        guard let suffix = id.split(separator: ".").last.map(String.init) else { return nil }
        return bySuffix[suffix]
    }

    private static let bySuffix: [String: String] = [
        // Xbox / Switch face buttons
        "a": "a.circle", "b": "b.circle", "x": "x.circle", "y": "y.circle",
        // PlayStation shapes
        "cross": "xmark", "circle": "circle", "square": "square", "triangle": "triangle",
        // D-pad + stick clicks
        "l3": "l.joystick.press.down", "r3": "r.joystick.press.down",
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/MappingControlSymbolsTests`
Expected: PASS.

- [ ] **Step 5: Use the glyph in the detail pane**

In `WaveBird/UI/ProfileDetailPane.swift`, replace the `Buttons` section `Picker`'s `label:` closure:

```swift
                    } label: {
                        if let glyph = MappingControlSymbols.symbol(forControlID: control.id) {
                            Label(control.displayName, systemImage: glyph)
                        } else {
                            Text(control.displayName)
                        }
                    }
```

- [ ] **Step 6: Build**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add WaveBird/UI/MappingControlSymbols.swift WaveBird/UI/ProfileDetailPane.swift WaveBirdTests/ProfileAppearanceTests.swift
git commit -m "feat: glyphs on mapping rows

Prefix each emulated control row with an SF Symbol where a faithful one
exists (face buttons, PS shapes, stick clicks); text-only otherwise.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Symbol+color in the "Use profile" pickers

**Files:**
- Modify: `WaveBird/UI/ProfilePickerSheet.swift:33-68`
- Modify: `WaveBird/UI/ControllerDetailSheet.swift:~150-172` (the "Use profile" `Picker`)

**Interfaces:**
- Consumes: `ProfileAppearance.resolve`.

- [ ] **Step 1: Update the first-connect picker**

In `WaveBird/UI/ProfilePickerSheet.swift`, replace the `Picker` body and delete the `iconName(forOutputModeID:)` helper:

```swift
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
```

Delete this now-unused method from the same file:

```swift
    private func iconName(forOutputModeID id: String) -> String {
        switch id {
        case "xboxSeries": "xbox.logo"
        case "dualShock4", "dualSense": "playstation.logo"
        default: "gamecontroller.fill"
        }
    }
```

- [ ] **Step 2: Update the detail-sheet "Use profile" picker**

In `WaveBird/UI/ControllerDetailSheet.swift`, replace the two `Label(profile.name, systemImage: Self.iconName(forOutputModeID: profile.baseModeID))` lines inside the "Use profile" `Picker` with appearance-driven labels:

```swift
                        ForEach(coordinator.mappingProfiles.builtInProfiles) { profile in
                            let appearance = ProfileAppearance.resolve(profile)
                            Label {
                                Text(profile.name)
                            } icon: {
                                Image(systemName: appearance.symbolName).foregroundStyle(appearance.color)
                            }
                            .tag(profile.id)
                        }
                        if !coordinator.mappingProfiles.customProfiles.isEmpty {
                            Divider()
                            ForEach(coordinator.mappingProfiles.customProfiles) { profile in
                                let appearance = ProfileAppearance.resolve(profile)
                                Label {
                                    Text(profile.name)
                                } icon: {
                                    Image(systemName: appearance.symbolName).foregroundStyle(appearance.color)
                                }
                                .tag(profile.id)
                            }
                        }
```

Note: if `Self.iconName(forOutputModeID:)` in `ControllerDetailSheet.swift` is now unused, delete it. If it is still referenced elsewhere in that file (e.g. a header icon), leave it. Verify with:
`grep -n 'iconName' WaveBird/UI/ControllerDetailSheet.swift`

- [ ] **Step 3: Build**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add WaveBird/UI/ProfilePickerSheet.swift WaveBird/UI/ControllerDetailSheet.swift
git commit -m "feat: profile symbol+color in Use-profile pickers

First-connect and detail-sheet profile pickers now render each
profile's tinted symbol instead of a base-mode-only icon.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**PHASE 1 CHECKPOINT:** Run the full suite and build. All Phase 1 work is cosmetic — no hardware pass needed. Confirm Settings → Profiles shows the two-pane editor, selecting a profile shows its mapping, symbol/color pickers work, `+`/`−` add/delete (defaults undeletable), and rows show tinted glyphs.

---

## PHASE 2 — Stick transforms (changes input bytes — NEEDS HARDWARE PASS)

### Task 7: Stick transform math

**Files:**
- Create: `WaveBird/Core/StickTransform.swift`
- Modify: `WaveBird/Core/ControllerState.swift` (append an extension method)
- Test: `WaveBirdTests/MappingTests.swift:<append new suite>`

**Interfaces:**
- Produces: `enum StickRotation: String, CaseIterable, Codable, Sendable, Hashable, Identifiable` (cases `none, cw90, deg180, ccw90`); `struct StickTransform: Codable, Sendable, Hashable` (`invertX`, `invertY: Bool`, `rotation: StickRotation`, `var isIdentity: Bool`); `ControllerState.applyingStickTransforms(left: StickTransform, right: StickTransform) -> ControllerState`.

- [ ] **Step 1: Write the failing test**

Append to `WaveBirdTests/MappingTests.swift`:

```swift
struct StickTransformTests {
    private func s(_ lx: Int16, _ ly: Int16, _ rx: Int16, _ ry: Int16) -> ControllerState {
        var st = ControllerState.zero
        st.leftStick = SIMD2(lx, ly)
        st.rightStick = SIMD2(rx, ry)
        return st
    }

    @Test func identityReturnsUnchanged() {
        let input = s(100, -200, 300, 400)
        let out = input.applyingStickTransforms(left: .init(), right: .init())
        #expect(out.leftStick == input.leftStick)
        #expect(out.rightStick == input.rightStick)
    }

    @Test func invertVerticalNegatesYOnly() {
        let out = s(100, -200, 0, 0).applyingStickTransforms(
            left: .init(invertX: false, invertY: true, rotation: .none), right: .init())
        #expect(out.leftStick == SIMD2<Int16>(100, 200))
    }

    @Test func invertHorizontalNegatesXOnly() {
        let out = s(100, -200, 0, 0).applyingStickTransforms(
            left: .init(invertX: true, invertY: false, rotation: .none), right: .init())
        #expect(out.leftStick == SIMD2<Int16>(-100, -200))
    }

    @Test func rotationsFollowTheDefinedConvention() {
        // cw90: (x,y)->(y,-x); deg180: (x,y)->(-x,-y); ccw90: (x,y)->(-y,x)
        let base = s(100, -200, 0, 0)
        #expect(base.applyingStickTransforms(left: .init(invertX: false, invertY: false, rotation: .cw90), right: .init()).leftStick == SIMD2<Int16>(-200, -100))
        #expect(base.applyingStickTransforms(left: .init(invertX: false, invertY: false, rotation: .deg180), right: .init()).leftStick == SIMD2<Int16>(-100, 200))
        #expect(base.applyingStickTransforms(left: .init(invertX: false, invertY: false, rotation: .ccw90), right: .init()).leftStick == SIMD2<Int16>(200, 100))
    }

    @Test func neutralStaysNeutralUnderEveryTransform() {
        for rot in StickRotation.allCases {
            for ix in [false, true] {
                for iy in [false, true] {
                    let t = StickTransform(invertX: ix, invertY: iy, rotation: rot)
                    let out = ControllerState.zero.applyingStickTransforms(left: t, right: t)
                    #expect(out.leftStick == SIMD2<Int16>(0, 0))
                    #expect(out.rightStick == SIMD2<Int16>(0, 0))
                }
            }
        }
    }

    @Test func railsSurviveNegation() {
        let out = s(-2047, 2047, 0, 0).applyingStickTransforms(
            left: .init(invertX: true, invertY: true, rotation: .none), right: .init())
        #expect(out.leftStick == SIMD2<Int16>(2047, -2047))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/StickTransformTests`
Expected: FAIL — `cannot find 'StickTransform' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `WaveBird/Core/StickTransform.swift`:

```swift
import Foundation

// Rigid stick reorientation. Raw values are persistence format — never rename.
enum StickRotation: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case none, cw90, deg180, ccw90
    var id: String { rawValue }

    var degrees: Int {
        switch self {
        case .none: 0
        case .cw90: 90
        case .deg180: 180
        case .ccw90: 270
        }
    }
}

// Per-stick transform applied before the output encoder. Rotation is applied
// first, then axis inversion. Defaulted fields so an older profile blob that
// predates transforms decodes to a no-op.
struct StickTransform: Codable, Sendable, Hashable {
    var invertX: Bool = false
    var invertY: Bool = false
    var rotation: StickRotation = .none

    var isIdentity: Bool { !invertX && !invertY && rotation == .none }
}
```

Append to `WaveBird/Core/ControllerState.swift` (inside the same `extension ControllerState` block that holds `invertingY`, or a new extension):

```swift
    // Apply per-stick rigid transforms (rotation first, then inversion) on the
    // centered 12-bit sticks. Presentation-agnostic: runs before the encoder,
    // same stage as invertingY. Identity transforms return self untouched.
    func applyingStickTransforms(left: StickTransform, right: StickTransform) -> ControllerState {
        guard !left.isIdentity || !right.isIdentity else { return self }
        var copy = self
        copy.leftStick = Self.transform(leftStick, left)
        copy.rightStick = Self.transform(rightStick, right)
        return copy
    }

    private static func transform(_ v: SIMD2<Int16>, _ t: StickTransform) -> SIMD2<Int16> {
        var x = Int(v.x)
        var y = Int(v.y)
        switch t.rotation {
        case .none:   break
        case .cw90:   (x, y) = (y, -x)
        case .deg180: (x, y) = (-x, -y)
        case .ccw90:  (x, y) = (-y, x)
        }
        if t.invertX { x = -x }
        if t.invertY { y = -y }
        return SIMD2(Int16(clamping: x), Int16(clamping: y))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/StickTransformTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Core/StickTransform.swift WaveBird/Core/ControllerState.swift WaveBirdTests/MappingTests.swift
git commit -m "feat: stick transform math (invert H/V + 4-way rotate)

Rigid per-stick reorientation on the 12-bit centered sticks, rotation
then inversion; identity returns self. Golden-byte tests pin the math.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Carry transforms through the mapping spec

**Files:**
- Modify: `WaveBird/Core/ButtonMapping.swift` (`ResolvedMappingSpec`, `applyingMapping`)
- Modify: `WaveBird/Profiles/MappingProfile.swift` (add transform fields + custom decode; extend `resolve`)
- Test: `WaveBirdTests/MappingTests.swift:<append>`

**Interfaces:**
- Consumes: `StickTransform` (Task 7).
- Produces: `MappingProfile.leftStick: StickTransform`, `MappingProfile.rightStick: StickTransform` (defaulted); `ResolvedMappingSpec.leftStick`/`.rightStick`; `ResolvedMappingSpec.isDefault` now also requires no-op transforms; `applyingMapping` applies transforms; `resolve(profile:)` fills them.

- [ ] **Step 1: Write the failing test**

Append to `WaveBirdTests/MappingTests.swift`:

```swift
struct MappingSpecTransformTests {
    @Test func oldBlobWithoutTransformsDecodesToIdentity() throws {
        let json = """
        {"id":"a","name":"Legacy","baseModeID":"xboxSeries","mapping":{}}
        """
        let profile = try JSONDecoder().decode(MappingProfile.self, from: Data(json.utf8))
        #expect(profile.leftStick.isIdentity)
        #expect(profile.rightStick.isIdentity)
    }

    @Test func resolveCarriesTransforms() {
        var profile = MappingProfile(id: "a", name: "Sideways", baseModeID: "switchPro")
        profile.leftStick = StickTransform(invertX: false, invertY: false, rotation: .cw90)
        let spec = ResolvedMappingSpec.resolve(profile: profile)
        #expect(spec.leftStick.rotation == .cw90)
        #expect(!spec.isDefault)  // a transform makes the spec non-default
    }

    @Test func identitySpecStillFastPaths() {
        // No overrides AND no transforms => isDefault => untouched passthrough.
        let spec = ResolvedMappingSpec.resolve(profile:
            MappingProfile(id: "d", name: "Default", baseModeID: "switchPro"))
        #expect(spec.isDefault)
        var st = ControllerState.zero
        st.leftStick = SIMD2(100, -200)
        #expect(st.applyingMapping(spec).leftStick == SIMD2<Int16>(100, -200))
    }

    @Test func applyingMappingAppliesTransform() {
        var profile = MappingProfile(id: "a", name: "Flip", baseModeID: "switchPro")
        profile.leftStick = StickTransform(invertX: false, invertY: true, rotation: .none)
        let spec = ResolvedMappingSpec.resolve(profile: profile)
        var st = ControllerState.zero
        st.leftStick = SIMD2(100, -200)
        #expect(st.applyingMapping(spec).leftStick == SIMD2<Int16>(100, 200))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/MappingSpecTransformTests`
Expected: FAIL — `value of type 'MappingProfile' has no member 'leftStick'`.

- [ ] **Step 3a: Add transform fields + back-compat decode to MappingProfile**

In `WaveBird/Profiles/MappingProfile.swift`, add the two stored properties to the struct (after `colorID`):

```swift
    var symbolName: String? = nil
    var colorID: String? = nil
    var leftStick: StickTransform = .init()
    var rightStick: StickTransform = .init()
```

`leftStick`/`rightStick` are non-optional with defaults, so the synthesized `Decodable` would reject old blobs missing those keys. Add a tolerant custom decoder in an **extension** (keeps the memberwise init) at the bottom of the same file:

```swift
extension MappingProfile {
    enum CodingKeys: String, CodingKey {
        case id, name, baseModeID, mapping, symbolName, colorID, leftStick, rightStick
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseModeID = try c.decode(String.self, forKey: .baseModeID)
        mapping = try c.decodeIfPresent([String: MappingChoice].self, forKey: .mapping) ?? [:]
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName)
        colorID = try c.decodeIfPresent(String.self, forKey: .colorID)
        leftStick = try c.decodeIfPresent(StickTransform.self, forKey: .leftStick) ?? .init()
        rightStick = try c.decodeIfPresent(StickTransform.self, forKey: .rightStick) ?? .init()
    }
}
```

- [ ] **Step 3b: Extend ResolvedMappingSpec + applyingMapping**

In `WaveBird/Core/ButtonMapping.swift`, extend `ResolvedMappingSpec`:

```swift
struct ResolvedMappingSpec: Sendable {
    enum Source: Sendable, Hashable {
        case off
        case physical(PhysicalButton)
    }

    struct Override: Sendable {
        let driver: ControlDriver
        let source: Source
    }

    let overrides: [Override]
    var leftStick: StickTransform = .init()
    var rightStick: StickTransform = .init()

    var isDefault: Bool { overrides.isEmpty && leftStick.isIdentity && rightStick.isIdentity }

    static let identity = ResolvedMappingSpec(overrides: [])
}
```

In the same file, apply transforms inside `applyingMapping` (after the override loop, before `return out`):

```swift
    func applyingMapping(_ spec: ResolvedMappingSpec) -> ControllerState {
        guard !spec.isDefault else { return self }
        var out = self
        for override in spec.overrides {
            Self.clear(override.driver, in: &out)
        }
        for override in spec.overrides {
            guard case .physical(let button) = override.source,
                  buttons.contains(button.buttonSetMember) else { continue }
            Self.set(override.driver, in: &out)
        }
        return out.applyingStickTransforms(left: spec.leftStick, right: spec.rightStick)
    }
```

- [ ] **Step 3c: Fill transforms in resolve**

In `WaveBird/Profiles/MappingProfile.swift`, update `ResolvedMappingSpec.resolve(profile:)` to carry the transforms:

```swift
    static func resolve(profile: MappingProfile) -> ResolvedMappingSpec {
        let controls = MappingControls.controls(forModeID: profile.baseModeID)
        var overrides: [Override] = []
        for control in controls {
            guard let choice = profile.mapping[control.id] else { continue }
            switch choice {
            case .off:
                overrides.append(Override(driver: control.driver, source: .off))
            case .physical(let button):
                overrides.append(Override(driver: control.driver, source: .physical(button)))
            }
        }
        return ResolvedMappingSpec(overrides: overrides,
                                   leftStick: profile.leftStick,
                                   rightStick: profile.rightStick)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/MappingSpecTransformTests`
Expected: PASS. Then the full suite (guards the existing `MappingTransformTests` identity/override behavior is unchanged):
Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Profiles/MappingProfile.swift WaveBird/Core/ButtonMapping.swift WaveBirdTests/MappingTests.swift
git commit -m "feat: carry stick transforms through the mapping spec

MappingProfile gains left/right StickTransform (tolerant decode for old
blobs); ResolvedMappingSpec carries them and applyingMapping applies
them, with the identity fast-path preserved.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Transform UI in the detail pane

**Files:**
- Modify: `WaveBird/UI/ProfileDetailPane.swift` (add a "Sticks" section)

**Interfaces:**
- Consumes: `MappingProfile.leftStick`/`.rightStick`, `StickTransform`, `StickRotation`.

- [ ] **Step 1: Add the Sticks section**

In `WaveBird/UI/ProfileDetailPane.swift`, add a new `Section` after the `Buttons` section (still inside `Form`):

```swift
            Section("Sticks") {
                stickControls("Left Stick", transform: $draft.leftStick)
                stickControls("Right Stick", transform: $draft.rightStick)
            }
```

Add this helper method to `ProfileDetailPane` (near `choiceBinding`):

```swift
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
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add WaveBird/UI/ProfileDetailPane.swift
git commit -m "feat: per-stick transform controls in profile editor

Left/right invert-horizontal, invert-vertical, and a 0/90/180/270
rotation picker, live-committed like the rest of the detail pane.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: Retire AxisSettings (pipeline + UI + migration)

**Files:**
- Modify: `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift` (solo dispatch ~21,44-47; pair dispatch ~85,108-111)
- Modify: `WaveBird/Bridge/BridgeCoordinator.swift` (remove `axisSettingsBySerial`, `axisSettings(for:)`, `axisSettings(forSerial:)`, `pairAxisSettings()`; add migration call)
- Modify: `WaveBird/UI/ControllerDetailSheet.swift` (remove `axis` binding at the call site, the `axis:` param of `generalTab`, the `if let axis { StickSettingsSection(...) }`, and the `StickSettingsSection` struct)
- Modify: `WaveBird/Core/ControllerState.swift` (remove `invertingY` + `negate`)
- Delete: `WaveBird/Profiles/AxisSettings.swift`
- Create: `WaveBird/Profiles/LegacyMigrations.swift`

**Interfaces:**
- Consumes: nothing new. Removes `AxisSettings` from the public surface.
- Produces: `enum LegacyMigrations { static func dropLegacyAxisSettings(_ defaults: UserDefaults) }`.

- [ ] **Step 1: Rewire the solo dispatch task**

In `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift`, delete the `let axis = axisSettings(for: record)` line (~line 21). Then replace the solo state-build block:

```swift
                let inv = axis.snapshot()
                let state = parsed
                    .invertingY(left: inv.invertLeftY, right: inv.invertRightY)
                    .applyingMapping(mapBox.current)
```

with:

```swift
                let state = parsed.applyingMapping(mapBox.current)
```

- [ ] **Step 2: Rewire the pair dispatch task**

In the same file, delete `let axis = pairAxisSettings()` (~line 85). Then replace:

```swift
                let inv = axis.snapshot()
                let mapped = merged
                    .invertingY(left: inv.invertLeftY, right: inv.invertRightY)
                    .applyingMapping(mapBox.current)
```

with:

```swift
                let mapped = merged.applyingMapping(mapBox.current)
```

- [ ] **Step 3: Remove AxisSettings from the coordinator**

In `WaveBird/Bridge/BridgeCoordinator.swift`, delete these members (lines ~165-180):

```swift
    var axisSettingsBySerial: [String: AxisSettings] = [:]

    func axisSettings(for record: DeviceRecord) -> AxisSettings {
        axisSettings(forSerial: settingsKey(for: record))
    }

    func axisSettings(forSerial serial: String) -> AxisSettings {
        if let existing = axisSettingsBySerial[serial] { return existing }
        let made = AxisSettings(serial: serial)
        axisSettingsBySerial[serial] = made
        return made
    }

    func pairAxisSettings() -> AxisSettings {
        axisSettings(forSerial: joyConPairSerial() ?? "joycon-pair")
    }
```

- [ ] **Step 4: Remove the Sticks UI from the detail sheet**

In `WaveBird/UI/ControllerDetailSheet.swift`:

Delete the `axis` binding at the call site:

```swift
        let axis = isPair
            ? coordinator.pairAxisSettings()
            : serial.map { coordinator.axisSettings(forSerial: $0) }
```

Find where `generalTab(...)` is called and remove the `axis:` argument. Change the signature:

```swift
    private func generalTab(live: DeviceRecord?, paired: KnownController?, xbox: XboxOutputSettings?) -> some View {
```

Delete the section that renders it:

```swift
            if let axis {
                StickSettingsSection(settings: axis)
            }
```

Delete the `StickSettingsSection` struct entirely:

```swift
private struct StickSettingsSection: View {
    @Bindable var settings: AxisSettings
    var body: some View {
        Section("Sticks") {
            Toggle("Invert Left Stick Y-Axis", isOn: $settings.invertLeftY)
            Toggle("Invert Right Stick Y-Axis", isOn: $settings.invertRightY)
        }
    }
}
```

(Stick inversion now lives in the profile editor, per-profile.)

- [ ] **Step 5: Remove invertingY and delete AxisSettings**

In `WaveBird/Core/ControllerState.swift`, delete the `invertingY(left:right:)` method and the `private static func negate` helper (confirm no other caller first: `grep -rn 'invertingY\|Self.negate\|\.negate(' WaveBird/` — expect no hits after Steps 1–2).

Then delete the file:

```bash
git rm WaveBird/Profiles/AxisSettings.swift
```

- [ ] **Step 6: Add the drop-migration**

Create `WaveBird/Profiles/LegacyMigrations.swift`:

```swift
import Foundation

// One-time UserDefaults cleanups for superseded features.
enum LegacyMigrations {
    // Per-serial "WaveBird.axis.<serial>" Y-inversion is replaced by per-profile
    // stick transforms. Profiles are shared across controllers while the old
    // keys were per-serial, so there is no faithful migration — drop the orphans.
    static func dropLegacyAxisSettings(_ defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("WaveBird.axis.") {
            defaults.removeObject(forKey: key)
        }
    }
}
```

Call it once at startup. In `WaveBird/Bridge/BridgeCoordinator.swift`, add as the first statement of `func start()`:

```swift
        LegacyMigrations.dropLegacyAxisSettings()
```

(Find the method with `grep -n 'func start(' WaveBird/Bridge/BridgeCoordinator.swift`.)

- [ ] **Step 7: Build and test**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. Then:
Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS. Confirm no dangling references:
`grep -rn 'AxisSettings\|invertingY' WaveBird/` → expect no hits.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: retire AxisSettings in favor of profile transforms

Route stick inversion through profile stick transforms; remove the
per-serial AxisSettings type, coordinator plumbing, detail-sheet Sticks
UI, and invertingY. Drop orphaned WaveBird.axis.* keys on launch.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**PHASE 2 CHECKPOINT — HARDWARE PASS REQUIRED.** The stick-transform pipeline changes input bytes. Validate on real hardware:
1. A profile with no transforms produces bit-identical sticks to before (regression).
2. Invert Vertically / Horizontally flip the expected axis in a game or the browser gamepad tester.
3. Rotate 90°/270° on a single sideways Joy-Con yields the correct "up = up" orientation; confirm which rotation value each Joy-Con orientation needs and note it (the picker exposes all four; code just implements the rigid math).
4. Live-edit propagation: changing a profile's transform while a controller using it is connected takes effect without reconnect.
5. Merged Joy-Con pair: per-stick transforms apply to the merged output.

---

## Self-Review Notes (author)

- **Spec coverage:** §1 master/detail → Task 4; §2 symbol+color → Tasks 1–3, surfaced in Tasks 4 & 6; §3 mapping-row symbols → Task 5; §4 transforms + AxisSettings retirement + drop-migration → Tasks 7–10; §5 work split → Phase 1 (Tasks 1–6) / Phase 2 (Tasks 7–10); Testing → Tasks 1–3,5,7,8 unit tests, Phase-2 hardware checkpoint. All covered.
- **Type consistency:** `ProfileAppearance.resolve(_:)`, `ProfileColor.color`, `ProfileSymbol.defaultAppearance(forBaseModeID:)`, `MappingControlSymbols.symbol(forControlID:)`, `StickTransform`/`StickRotation`, `ControllerState.applyingStickTransforms(left:right:)`, and `ResolvedMappingSpec.leftStick/.rightStick` names are used identically across the tasks that define and consume them.
- **Known verification points for the implementer:** confirm `HIDOutputCatalog.Entry`, `catalog.resolved(id:)`, and `catalog.firstAllowListedID` member names against `WaveBird/HID/HIDOutputProfile.swift` while building Task 4; confirm the exact call site / argument list of `generalTab(...)` in Task 10.
