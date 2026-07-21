# Multi-Input Control Mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one output control be driven by multiple physical inputs (OR), including GameCube analog trigger travel, so a single profile serves several controller form factors.

**Architecture:** Generalize the per-control mapping choice from one source to a set of `MappingSource`s (digital button or analog trigger), OR'd in `applyingMapping`. The editor's single-select picker becomes a stay-open popover checklist. Analog sources are offered only for analog-trigger outputs.

**Tech Stack:** Swift 6.2 (strict concurrency, `nonisolated` default), SwiftUI, Swift Testing.

## Global Constraints

- Preserve the `applyingMapping` identity fast-path (`isDefault` → return `self` unchanged); the default hot path stays bit-exact.
- No wire-protocol, output-catalog-identity, or stick-transform changes.
- Persistence is an array of string tokens per control (`["off"]` or source tokens); no legacy single-string decode.
- Analog sources (`leftAnalogTrigger`/`rightAnalogTrigger`) are offered in the UI **only** for controls whose driver `isAnalogTrigger`. Digital sources are offered for all controls.
- Two hardware-validation checkpoints: after Task 3 (digital OR, button→trigger full-press) and after Task 4 (GameCube analog trigger sources). Neither the compiler nor the unit suite validates gamepad feel.
- Build: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
- Test: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`

## File Structure

- Create: `WaveBird/Core/MappingSource.swift` — the `MappingSource` enum (source vocabulary): token persistence, `displayName`, `family`, and the `isPressed`/`analogValue` state readers.
- Modify: `WaveBird/Core/ButtonMapping.swift` — replace `MappingChoice` with the set model + array-token `Codable`; change `ResolvedMappingSpec.Override.source` → `sources: [MappingSource]`; rewrite `applyingMapping`'s drive logic; add `ControlDriver.isAnalogTrigger`. Delete the old `ResolvedMappingSpec.Source` enum.
- Modify: `WaveBird/Profiles/MappingProfile.swift` — update `ResolvedMappingSpec.resolve` to the new choice/override shape.
- Modify: `WaveBird/UI/ProfileDetailPane.swift` — Task 2 adapts the picker to the new model (still single-select); Task 3 replaces it with the popover checklist; Task 4 adds analog sources.
- Modify: `WaveBirdTests/MappingTests.swift` — migrate existing tests to the new API and add multi-source + analog unit tests.

---

### Task 1: `MappingSource` vocabulary type

**Files:**
- Create: `WaveBird/Core/MappingSource.swift`
- Test: `WaveBirdTests/MappingTests.swift`

**Interfaces:**
- Consumes: `PhysicalButton` (`rawValue`, `displayName`, `family`, `buttonSetMember`), `ControllerState` (`buttons`, `shoulders.leftTriggerAnalog`, `shoulders.rightTriggerAnalog`).
- Produces:
  - `enum MappingSource: Sendable, Hashable { case button(PhysicalButton); case leftAnalogTrigger; case rightAnalogTrigger }`
  - `var token: String`, `init?(token: String)`
  - `var displayName: String`, `var family: PhysicalButton.Family`
  - `func isPressed(in: ControllerState) -> Bool`, `func analogValue(in: ControllerState) -> UInt8`

- [ ] **Step 1: Write the failing tests**

Add to `WaveBirdTests/MappingTests.swift`:

```swift
struct MappingSourceTests {

    @Test func tokensRoundTrip() {
        for button in PhysicalButton.allCases {
            let src = MappingSource.button(button)
            #expect(MappingSource(token: src.token) == src)
        }
        #expect(MappingSource(token: "analogL") == .leftAnalogTrigger)
        #expect(MappingSource(token: "analogR") == .rightAnalogTrigger)
        #expect(MappingSource.leftAnalogTrigger.token == "analogL")
        #expect(MappingSource.rightAnalogTrigger.token == "analogR")
    }

    @Test func unknownAndSentinelTokensAreNil() {
        #expect(MappingSource(token: "off") == nil)
        #expect(MappingSource(token: "default") == nil)
        #expect(MappingSource(token: "nonsense") == nil)
    }

    @Test func metadataForAnalogSources() {
        #expect(MappingSource.leftAnalogTrigger.displayName == "Left Trigger (Analog)")
        #expect(MappingSource.leftAnalogTrigger.family == .gameCube)
        #expect(MappingSource.button(.gl).displayName == "GL Button")
        #expect(MappingSource.button(.gl).family == .pro)
    }

    @Test func buttonSourceReadsButtonSet() {
        var s = ControllerState.zero
        s.buttons = [.gl]
        #expect(MappingSource.button(.gl).isPressed(in: s))
        #expect(!MappingSource.button(.gr).isPressed(in: s))
        #expect(MappingSource.button(.gl).analogValue(in: s) == 0xFF)
        #expect(MappingSource.button(.gr).analogValue(in: s) == 0)
    }

    @Test func analogSourceReadsShoulderTravel() {
        var s = ControllerState.zero
        s.shoulders = StandardShoulders(leftTriggerAnalog: 0x80)
        #expect(MappingSource.leftAnalogTrigger.analogValue(in: s) == 0x80)
        #expect(MappingSource.leftAnalogTrigger.isPressed(in: s))
        #expect(MappingSource.rightAnalogTrigger.analogValue(in: s) == 0)
        #expect(!MappingSource.rightAnalogTrigger.isPressed(in: s))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/MappingSourceTests`
Expected: FAIL to build — "Cannot find 'MappingSource' in scope".

- [ ] **Step 3: Create the type**

Create `WaveBird/Core/MappingSource.swift`:

```swift
import Foundation

// A single physical input a mapping row can draw from: a digital button, or
// GameCube analog trigger travel. Tokens are the persistence format (inside a
// MappingChoice JSON array) — never rename. Analog cases are offered by the
// editor only for analog-trigger outputs (see ControlDriver.isAnalogTrigger).
enum MappingSource: Sendable, Hashable {
    case button(PhysicalButton)
    case leftAnalogTrigger
    case rightAnalogTrigger

    var token: String {
        switch self {
        case .button(let b): b.rawValue
        case .leftAnalogTrigger: "analogL"
        case .rightAnalogTrigger: "analogR"
        }
    }

    init?(token: String) {
        switch token {
        case "analogL": self = .leftAnalogTrigger
        case "analogR": self = .rightAnalogTrigger
        default:
            guard let button = PhysicalButton(rawValue: token) else { return nil }
            self = .button(button)
        }
    }

    var displayName: String {
        switch self {
        case .button(let b): b.displayName
        case .leftAnalogTrigger: "Left Trigger (Analog)"
        case .rightAnalogTrigger: "Right Trigger (Analog)"
        }
    }

    var family: PhysicalButton.Family {
        switch self {
        case .button(let b): b.family
        case .leftAnalogTrigger, .rightAnalogTrigger: .gameCube
        }
    }

    // Digital view: is this source active? Analog cases read >0 travel.
    func isPressed(in state: ControllerState) -> Bool {
        switch self {
        case .button(let b): state.buttons.contains(b.buttonSetMember)
        case .leftAnalogTrigger: state.shoulders.leftTriggerAnalog > 0
        case .rightAnalogTrigger: state.shoulders.rightTriggerAnalog > 0
        }
    }

    // Analog view: 0xFF for a pressed button, else the live trigger travel.
    func analogValue(in state: ControllerState) -> UInt8 {
        switch self {
        case .button(let b): state.buttons.contains(b.buttonSetMember) ? 0xFF : 0
        case .leftAnalogTrigger: state.shoulders.leftTriggerAnalog
        case .rightAnalogTrigger: state.shoulders.rightTriggerAnalog
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/MappingSourceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Core/MappingSource.swift WaveBirdTests/MappingTests.swift
git commit -m "feat: add MappingSource vocabulary type" \
  -m "Digital button or GameCube analog trigger travel, with token persistence
and state readers (isPressed/analogValue)." \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Multi-source model, apply, and resolve

Replace the single-source `MappingChoice`/`Override.source` with the OR'd set model and rewrite `applyingMapping`. The editor keeps its single-select picker for now (adapted to the new model) so the tree stays compiling; the multi-select UI is Task 3.

**Files:**
- Modify: `WaveBird/Core/ButtonMapping.swift`
- Modify: `WaveBird/Profiles/MappingProfile.swift:48-68`
- Modify: `WaveBird/UI/ProfileDetailPane.swift` (`choiceBinding` only)
- Test: `WaveBirdTests/MappingTests.swift`

**Interfaces:**
- Consumes: `MappingSource` (Task 1), `ControlDriver`, `ControllerState`, `MappingControls.controls(forModeID:)`.
- Produces:
  - `enum MappingChoice: Sendable, Hashable, Codable { case off; case sources([MappingSource]) }`
  - `ResolvedMappingSpec.Override { let driver: ControlDriver; let sources: [MappingSource] }` (empty `sources` = Off)
  - `var ControlDriver.isAnalogTrigger: Bool`
  - unchanged: `ControllerState.applyingMapping(_:)`, `ResolvedMappingSpec.resolve(profile:)`

- [ ] **Step 1: Migrate existing tests and add new ones**

In `WaveBirdTests/MappingTests.swift`:

Delete the `mappingChoiceRawValues` test from `PhysicalButtonTests` (MappingChoice is no longer RawRepresentable). Keep `reservedSentinelsDontCollide` and `gripAndRailMembersMatch` as-is.

Replace `MappingProfileTests.mappingChoiceEncodesAsBareJSONString` with:

```swift
    @Test func mappingChoiceEncodesAsTokenArray() throws {
        let single = try JSONEncoder().encode(MappingChoice.sources([.button(.gl)]))
        #expect(String(data: single, encoding: .utf8) == "[\"gl\"]")
        let off = try JSONEncoder().encode(MappingChoice.off)
        #expect(String(data: off, encoding: .utf8) == "[\"off\"]")
        let multi = try JSONEncoder().encode(MappingChoice.sources([.button(.l), .button(.sl)]))
        #expect(String(data: multi, encoding: .utf8) == "[\"l\",\"sl\"]")
    }

    @Test func mappingChoiceDecodesTokenArray() throws {
        func decode(_ json: String) throws -> MappingChoice {
            try JSONDecoder().decode(MappingChoice.self, from: Data(json.utf8))
        }
        #expect(try decode("[\"off\"]") == .off)
        #expect(try decode("[\"l\",\"sl\"]") == .sources([.button(.l), .button(.sl)]))
        #expect(try decode("[\"l\",\"analogL\"]") == .sources([.button(.l), .leftAnalogTrigger]))
        // Unknown tokens are dropped.
        #expect(try decode("[\"l\",\"bogus\"]") == .sources([.button(.l)]))
    }
```

Update the `.physical`/`.off` literals in `MappingProfileTests` and `MappingProfileStoreTests`:

- `roundTripsThroughJSON`: `mapping: ["xboxSeries.leftBumper": .sources([.button(.gl)]), "xboxSeries.guide": .off]`
- `customMappingResolvesOverrides`: `mapping: ["xboxSeries.a": .sources([.button(.gl)]), "xboxSeries.guide": .off, "xboxSeries.unknownRow": .sources([.button(.gr)])]` (still expects `spec.overrides.count == 2`)
- `upsertPersistsAndReloads`: `mapping: ["dualSense.l2": .sources([.button(.gl)])]`

Rewrite `MappingTransformTests` to the `sources:` API and add multi-source + analog cases (replace the whole struct):

```swift
struct MappingTransformTests {

    private func state(buttons: ButtonSet, shoulders: StandardShoulders = StandardShoulders()) -> ControllerState {
        var s = ControllerState.zero
        s.buttons = buttons
        s.shoulders = shoulders
        s.leftStick = SIMD2(100, -200)
        return s
    }

    @Test func identitySpecIsUntouchedPassthrough() {
        let input = state(buttons: [.a, .zl, .gl],
                          shoulders: StandardShoulders(leftBumper: true, leftTriggerAnalog: 0x80))
        let out = input.applyingMapping(.identity)
        #expect(out.buttons == input.buttons)
        #expect(out.shoulders == input.shoulders)
        #expect(out.leftStick == input.leftStick)
    }

    @Test func singleSourceDrivesRemappedButton() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.b), sources: [.button(.gl)])
        ])
        let pressed = state(buttons: [.gl]).applyingMapping(spec)
        #expect(pressed.buttons.contains(.b))
        let bOnly = state(buttons: [.b]).applyingMapping(spec)
        #expect(!bOnly.buttons.contains(.b))
        #expect(pressed.buttons.contains(.gl))
    }

    @Test func orOfTwoButtonsDrivesControl() {
        // "Right Bumper ← R OR SR": either input fires it.
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .rightBumper, sources: [.button(.r), .button(.sr)])
        ])
        #expect(state(buttons: [.r]).applyingMapping(spec).shoulders.rightBumper)
        #expect(state(buttons: [.sr]).applyingMapping(spec).shoulders.rightBumper)
        #expect(!state(buttons: [.l]).applyingMapping(spec).shoulders.rightBumper)
    }

    @Test func buttonSourceDrivesTriggerAsFullPull() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .leftTrigger, sources: [.button(.gl)])
        ])
        let pressed = state(buttons: [.gl]).applyingMapping(spec)
        #expect(pressed.shoulders.leftTriggerDigital)
        #expect(pressed.shoulders.leftTriggerAnalog == 0xFF)
        // Remapping a trigger row clears the original source.
        let zl = state(buttons: [.zl],
                       shoulders: StandardShoulders(leftTriggerDigital: true, leftTriggerAnalog: 0xFF))
            .applyingMapping(spec)
        #expect(!zl.shoulders.leftTriggerDigital)
        #expect(zl.shoulders.leftTriggerAnalog == 0)
    }

    @Test func analogSourcePreservesTriggerTravel() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .rightTrigger, sources: [.leftAnalogTrigger])
        ])
        let out = state(buttons: [], shoulders: StandardShoulders(leftTriggerAnalog: 100))
            .applyingMapping(spec)
        #expect(out.shoulders.rightTriggerAnalog == 100)
        #expect(!out.shoulders.rightTriggerDigital)   // partial travel is not a click
    }

    @Test func triggerCombineTakesMaxContribution() {
        // Button (0xFF) vs analog (50) → max wins → full press.
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .leftTrigger, sources: [.button(.a), .leftAnalogTrigger])
        ])
        let out = state(buttons: [.a], shoulders: StandardShoulders(leftTriggerAnalog: 50))
            .applyingMapping(spec)
        #expect(out.shoulders.leftTriggerAnalog == 0xFF)
        #expect(out.shoulders.leftTriggerDigital)
    }

    @Test func offSuppressesControl() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.home), sources: [])
        ])
        let out = state(buttons: [.home]).applyingMapping(spec)
        #expect(!out.buttons.contains(.home))
    }

    @Test func defaultRowsPreserveAnalogTriggers() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.b), sources: [.button(.gl)])
        ])
        let out = state(buttons: [],
                        shoulders: StandardShoulders(leftTriggerAnalog: 0x80)).applyingMapping(spec)
        #expect(out.shoulders.leftTriggerAnalog == 0x80)
    }

    @Test func multiMemberDriverClearsAndSetsTogether() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons([.plus, .start]), sources: [.button(.gr)])
        ])
        let startOnly = state(buttons: [.start]).applyingMapping(spec)
        #expect(!startOnly.buttons.contains(.start))
        #expect(!startOnly.buttons.contains(.plus))
        let grPressed = state(buttons: [.gr]).applyingMapping(spec)
        #expect(grPressed.buttons.contains(.plus))
        #expect(grPressed.buttons.contains(.start))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: FAIL to build — `.sources`/`sources:` unknown, `MappingChoice.off` no longer RawRepresentable, etc.

- [ ] **Step 3: Rewrite `MappingChoice` in `ButtonMapping.swift`**

Replace the entire existing `MappingChoice` enum (the `RawRepresentable` version) with:

```swift
// One row's stored choice: drive the control from the OR of one or more
// physical sources, or disable it. Absence from the mapping dict = Default
// (copy-through). Persisted as a JSON array of source tokens; ["off"] = off.
enum MappingChoice: Sendable, Hashable, Codable {
    case off
    case sources([MappingSource])

    init(from decoder: any Decoder) throws {
        let tokens = try decoder.singleValueContainer().decode([String].self)
        if tokens.contains("off") {
            self = .off
        } else {
            self = .sources(tokens.compactMap(MappingSource.init(token:)))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .off: try container.encode(["off"])
        case .sources(let sources): try container.encode(sources.map(\.token))
        }
    }
}
```

- [ ] **Step 4: Add `ControlDriver.isAnalogTrigger` in `ButtonMapping.swift`**

Immediately after the `enum ControlDriver { … }` declaration, add:

```swift
extension ControlDriver {
    var isAnalogTrigger: Bool {
        switch self {
        case .leftTrigger, .rightTrigger: true
        default: false
        }
    }
}
```

- [ ] **Step 5: Change `Override` and rewrite the apply logic in `ButtonMapping.swift`**

In `ResolvedMappingSpec`, delete the nested `enum Source { … }` and change `Override` to:

```swift
    struct Override: Sendable {
        let driver: ControlDriver
        let sources: [MappingSource]   // empty = Off (clear only); non-empty = replace with the OR
    }
```

Replace the `applyingMapping` method body and its `set(_:in:)` helper with a `drive(_:from:reading:into:)` helper (keep `clear(_:in:)` exactly as-is):

```swift
    func applyingMapping(_ spec: ResolvedMappingSpec) -> ControllerState {
        guard !spec.isDefault else { return self }
        var out = self
        for override in spec.overrides {
            Self.clear(override.driver, in: &out)
        }
        for override in spec.overrides {
            Self.drive(override.driver, from: override.sources, reading: self, into: &out)
        }
        return out.applyingStickTransforms(left: spec.leftStick, right: spec.rightStick)
    }
```

```swift
    // Reads presses/travel from the ORIGINAL state, writes into the copy, so a
    // source can still drive its own default row too. Empty sources = Off:
    // the driver was cleared above and nothing is set.
    private static func drive(_ driver: ControlDriver, from sources: [MappingSource],
                              reading input: ControllerState, into state: inout ControllerState) {
        guard !sources.isEmpty else { return }
        switch driver {
        case .buttons(let members):
            if sources.contains(where: { $0.isPressed(in: input) }) {
                state.buttons.formUnion(members)
            }
        case .leftBumper:
            if sources.contains(where: { $0.isPressed(in: input) }) {
                state.shoulders.leftBumper = true
            }
        case .rightBumper:
            if sources.contains(where: { $0.isPressed(in: input) }) {
                state.shoulders.rightBumper = true
            }
        case .leftTrigger:
            let value = sources.map { $0.analogValue(in: input) }.max() ?? 0
            state.shoulders.leftTriggerAnalog = value
            state.shoulders.leftTriggerDigital = (value == 0xFF)
        case .rightTrigger:
            let value = sources.map { $0.analogValue(in: input) }.max() ?? 0
            state.shoulders.rightTriggerAnalog = value
            state.shoulders.rightTriggerDigital = (value == 0xFF)
        }
    }
```

- [ ] **Step 6: Update `resolve` in `MappingProfile.swift`**

Replace the `switch choice` block inside `ResolvedMappingSpec.resolve(profile:)` (lines ~56-62) with:

```swift
            switch choice {
            case .off:
                overrides.append(Override(driver: control.driver, sources: []))
            case .sources(let sources):
                guard !sources.isEmpty else { continue }   // empty = Default (defensive)
                overrides.append(Override(driver: control.driver, sources: sources))
            }
```

- [ ] **Step 7: Adapt `choiceBinding` in `ProfileDetailPane.swift` (still single-select)**

Replace the existing `choiceBinding(_:)` with a version backed by the new model (the picker's option tags are still `"default"`, `"off"`, and button raw values):

```swift
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
```

- [ ] **Step 8: Run the full suite**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS (all suites, including the migrated `MappingTransformTests`).

- [ ] **Step 9: Build the app**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 10: Commit**

```bash
git add WaveBird/Core/ButtonMapping.swift WaveBird/Profiles/MappingProfile.swift WaveBird/UI/ProfileDetailPane.swift WaveBirdTests/MappingTests.swift
git commit -m "feat: multi-source mapping model and OR apply" \
  -m "MappingChoice becomes an OR'd set of MappingSources (array-token JSON);
applyingMapping clears then drives each control from its sources, with
max-combine for analog triggers. Editor stays single-select for now." \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Popover-checklist multi-select UI (digital sources)

Replace the per-control single-select picker with a stay-open popover checklist. Analog sources are **not** offered yet (Task 4).

**Files:**
- Modify: `WaveBird/UI/ProfileDetailPane.swift`

**Interfaces:**
- Consumes: `MappingSource`, `MappingChoice`, `OutputControl` (`id`, `displayName`, `driver`), `PhysicalButton.Family.allCases`, `MappingControlSymbols.symbol(forControlID:)`.
- Produces: no new public API; internal `controlRow`, `mappingOptions`, `availableSources`, `summary`, and `@State activeMappingControlID`.

- [ ] **Step 1: Add popover state**

In `ProfileDetailPane`, next to the other `@State` properties, add:

```swift
    @State private var activeMappingControlID: String?
```

- [ ] **Step 2: Swap the ForEach body to `controlRow`**

In `body`, replace the `ForEach(MappingControls.controls(forModeID: draft.baseModeID)) { control in … }` picker block with:

```swift
                ForEach(MappingControls.controls(forModeID: draft.baseModeID)) { control in
                    controlRow(control)
                }
```

- [ ] **Step 3: Add the row + popover + helpers**

Delete `choiceBinding(_:)` (replaced) and add:

```swift
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    // Digital sources for every control; Task 4 adds analog sources for
    // analog-trigger outputs.
    private func availableSources(for control: OutputControl) -> [MappingSource] {
        PhysicalButton.allCases.map { MappingSource.button($0) }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **` (SourceKit cross-file "cannot find type" diagnostics from the editor are stale index noise; the build result is authoritative.)

- [ ] **Step 5: Run the suite (no regressions)**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add WaveBird/UI/ProfileDetailPane.swift
git commit -m "feat: multi-input mapping popover checklist" \
  -m "Per-control pull-down opens a stay-open popover of Default/Off plus
grouped source toggles; row shows a summary of the selection." \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 7: HARDWARE CHECKPOINT (digital OR)**

Not automatable. On real controllers verify: (a) mapping a control to two buttons (e.g. Right Bumper ← R + SR) fires from either; (b) mapping a button to a trigger (e.g. B → ZR) registers as a full press in a consuming app; (c) existing single-source profiles behave exactly as before. Note results in the commit/PR description.

---

### Task 4: Analog trigger sources in the editor (Commit B)

Surface the analog sources — already handled by the model/apply and unit-tested in Tasks 1-2 — in the popover, only for analog-trigger controls.

**Files:**
- Modify: `WaveBird/UI/ProfileDetailPane.swift` (`availableSources`)

**Interfaces:**
- Consumes: `ControlDriver.isAnalogTrigger` (Task 2), `MappingSource.leftAnalogTrigger`/`.rightAnalogTrigger` (Task 1).
- Produces: no new API.

- [ ] **Step 1: Offer analog sources for analog-trigger controls**

Replace `availableSources(for:)` with:

```swift
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
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run the suite**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add WaveBird/UI/ProfileDetailPane.swift
git commit -m "feat: analog trigger sources in mapping editor" \
  -m "Analog-trigger controls also offer Left/Right Trigger (Analog) sources so
trigger->trigger remaps stay analog." \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: HARDWARE CHECKPOINT (GameCube analog)**

Not automatable. On a GameCube controller verify: mapping an analog-trigger output (e.g. Xbox Left Trigger, DualSense L2) to "Left Trigger (Analog)" produces smooth analog travel in a consuming app (not just on/off); confirm the digital-flag rule (`value == 0xFF`) behaves acceptably where the output is digital (e.g. Switch Pro ZL). Note results in the commit/PR description.

---

## Self-Review

**Spec coverage:**
- §1 Source vocabulary → Task 1 (`MappingSource`, tokens, displayName/family) + Task 4 (UI gating). ✓
- §2 Choice model (`.off`/`.sources`, absent = Default) → Task 2. ✓
- §3 Resolve + OR/max apply, `isPressed`/`analogValue`, digital flag `== 0xFF` → Task 1 (readers) + Task 2 (drive/resolve). ✓
- §4 Popover checklist UI, summary text, `activeMappingControlID`, read-only disable → Task 3. ✓
- §5 Persistence (array tokens, unknown-drop, empty = Default) → Task 2 (Codable + resolve guard). ✓
- §6 Commit split (digital vs analog) → Tasks 1-3 (digital, hardware checkpoint) + Task 4 (analog, hardware checkpoint). ✓
- Testing section (OR, off, fast-path, decode round-trips, analog preserve/max/partial) → Task 1 + Task 2 tests. ✓

**Placeholder scan:** none — every step has exact code/commands.

**Type consistency:** `MappingSource(token:)`, `.token`, `.displayName`, `.family`, `.isPressed(in:)`, `.analogValue(in:)`, `MappingChoice.sources([MappingSource])`, `Override(driver:sources:)`, `ControlDriver.isAnalogTrigger`, `availableSources(for:)` are used consistently across tasks. `clear(_:in:)` is reused unchanged; `set(_:in:)` is removed and replaced by `drive(_:from:reading:into:)`.

## Notes

- The model/apply (Tasks 1-2) fully supports analog sources and is unit-tested there; analog is simply not *reachable through the UI* until Task 4, which keeps the two hardware checkpoints cleanly separated.
- SourceKit may emit "Cannot find type … in scope" for cross-file symbols in `ProfileDetailPane.swift`; the `xcodebuild` result is authoritative.
