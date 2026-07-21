# Nintendo Button Layout Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-profile "Use Nintendo Button Layout" toggle that flips the default face-button mapping for Xbox output from positional to by-label (fixing GameCube→Xbox A→A).

**Architecture:** A `Bool` on `MappingProfile`; a per-mode by-label face-source table in `MappingControls`; `resolve()` injects by-label default overrides for the four diamond face rows that aren't user-overridden; a conditional toggle in the profile editor.

**Tech Stack:** Swift 6.2 (strict concurrency, `nonisolated` default), SwiftUI, Swift Testing.

## Global Constraints

- The toggle changes ONLY the four diamond face buttons, and ONLY their Default resolution — an explicit user override for a face row always wins and is untouched.
- Preserve the `applyingMapping` identity fast-path: with the toggle off, nothing is injected and behavior is bit-identical to today.
- `MappingProfile.useNintendoLayout` is added with `decodeIfPresent(...) ?? false` in the existing tolerant `init(from:)`; existing profile blobs must still decode.
- By-label map is defined only for `xboxSeries`. `switchPro` (identity) and `dualShock4`/`dualSense` (PlayStation, opted out) have an empty map → toggle hidden and no-op there.
- No wire-protocol, output-catalog-identity, stick-transform, or multi-input-mapping changes.
- Build: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
- Test: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
- SourceKit may emit "Cannot find type … in scope" / "No such module 'Testing'" cross-file diagnostics — the `xcodebuild` result is authoritative.

## File Structure

- Modify: `WaveBird/Profiles/MappingProfile.swift` — add `useNintendoLayout` field + `CodingKeys` + tolerant decode; extend `ResolvedMappingSpec.resolve` to inject by-label overrides.
- Modify: `WaveBird/HID/MappingControls.swift` — add `nintendoLayoutSources(forModeID:)` and its table (xboxSeries only).
- Modify: `WaveBird/UI/ProfileDetailPane.swift` — conditional "Use Nintendo Button Layout" toggle at the top of the Buttons section.
- Modify: `WaveBirdTests/MappingTests.swift` — resolve/round-trip/end-to-end tests.

---

### Task 1: Model, by-label map, and resolve injection

**Files:**
- Modify: `WaveBird/HID/MappingControls.swift`
- Modify: `WaveBird/Profiles/MappingProfile.swift`
- Test: `WaveBirdTests/MappingTests.swift`

**Interfaces:**
- Consumes: `MappingSource.button(_:)`, `MappingControls.controls(forModeID:)`, `ResolvedMappingSpec.Override(driver:sources:)`, `PhysicalButton`.
- Produces:
  - `MappingProfile.useNintendoLayout: Bool` (default `false`)
  - `MappingControls.nintendoLayoutSources(forModeID:) -> [String: MappingSource]`
  - unchanged signature: `ResolvedMappingSpec.resolve(profile:) -> ResolvedMappingSpec`

- [ ] **Step 1: Write the failing tests**

Append to `WaveBirdTests/MappingTests.swift`:

```swift
struct NintendoLayoutTests {

    @Test func fieldRoundTripsAndDefaultsFalse() throws {
        var profile = MappingProfile(id: "n", name: "GC Xbox", baseModeID: "xboxSeries")
        profile.useNintendoLayout = true
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(MappingProfile.self, from: data) == profile)

        // A blob missing the key decodes to false.
        let legacy = """
        {"id":"a","name":"Old","baseModeID":"xboxSeries","mapping":{}}
        """
        #expect(try JSONDecoder().decode(MappingProfile.self, from: Data(legacy.utf8)).useNintendoLayout == false)
    }

    @Test func layoutMapDefinedOnlyForXbox() {
        #expect(MappingControls.nintendoLayoutSources(forModeID: "xboxSeries").count == 4)
        #expect(MappingControls.nintendoLayoutSources(forModeID: "switchPro").isEmpty)
        #expect(MappingControls.nintendoLayoutSources(forModeID: "dualShock4").isEmpty)
        #expect(MappingControls.nintendoLayoutSources(forModeID: "dualSense").isEmpty)
    }

    @Test func toggleInjectsByLabelDefaultsForXbox() {
        var profile = MappingProfile(id: "n", name: "GC", baseModeID: "xboxSeries")
        profile.useNintendoLayout = true
        let spec = ResolvedMappingSpec.resolve(profile: profile)
        #expect(!spec.isDefault)
        #expect(spec.overrides.count == 4)
        // Xbox A output (driver .buttons(.b)) is driven by Nintendo A.
        var st = ControllerState.zero
        st.buttons = [.a]
        #expect(st.applyingMapping(spec).buttons.contains(.b))    // Nintendo A -> Xbox A (reads .b)
        var st2 = ControllerState.zero
        st2.buttons = [.b]
        #expect(st2.applyingMapping(spec).buttons.contains(.a))   // Nintendo B -> Xbox B (reads .a)
    }

    @Test func userOverrideWinsOverToggle() {
        var profile = MappingProfile(id: "n", name: "GC", baseModeID: "xboxSeries")
        profile.useNintendoLayout = true
        profile.mapping = ["xboxSeries.a": .sources([.button(.gl)])]
        let spec = ResolvedMappingSpec.resolve(profile: profile)
        // 1 explicit override for .a + 3 injected by-label (b/x/y) = 4, no duplicate for .a.
        #expect(spec.overrides.count == 4)
        var st = ControllerState.zero
        st.buttons = [.gl]
        #expect(st.applyingMapping(spec).buttons.contains(.b))    // Xbox A still driven by GL, not Nintendo A
    }

    @Test func toggleIsNoOpForIdentityAndOptedOutModes() {
        for mode in ["switchPro", "dualShock4", "dualSense"] {
            var profile = MappingProfile(id: "n", name: "x", baseModeID: mode)
            profile.useNintendoLayout = true
            #expect(ResolvedMappingSpec.resolve(profile: profile).isDefault)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/NintendoLayoutTests`
Expected: FAIL to build — `useNintendoLayout` and `nintendoLayoutSources` don't exist.

- [ ] **Step 3: Add the by-label map to `MappingControls.swift`**

Add these members inside `enum MappingControls` (after `controls(forModeID:)`):

```swift
    // Nintendo-label source for each diamond face control, per output mode whose
    // diamond differs from Nintendo's. Empty for modes that are already identity
    // (switchPro) or opted out (PlayStation). Used to inject by-label defaults
    // when a profile's useNintendoLayout is on.
    static func nintendoLayoutSources(forModeID id: String) -> [String: MappingSource] {
        nintendoLayout[id] ?? [:]
    }

    private static let nintendoLayout: [String: [String: MappingSource]] = [
        "xboxSeries": [
            "xboxSeries.a": .button(.a),
            "xboxSeries.b": .button(.b),
            "xboxSeries.x": .button(.x),
            "xboxSeries.y": .button(.y),
        ],
    ]
```

- [ ] **Step 4: Add the `useNintendoLayout` field to `MappingProfile.swift`**

In `struct MappingProfile`, add after `rightStick`:

```swift
    var useNintendoLayout: Bool = false
```

In `extension MappingProfile`'s `CodingKeys`, add the case:

```swift
        case id, name, baseModeID, mapping, symbolName, colorID, leftStick, rightStick, useNintendoLayout
```

In `init(from:)`, add after the `rightStick` line:

```swift
        useNintendoLayout = try c.decodeIfPresent(Bool.self, forKey: .useNintendoLayout) ?? false
```

- [ ] **Step 5: Inject by-label defaults in `resolve`**

In `ResolvedMappingSpec.resolve(profile:)`, after the existing `for control in controls { … }` loop and before `return`, insert:

```swift
        if profile.useNintendoLayout {
            let byLabel = MappingControls.nintendoLayoutSources(forModeID: profile.baseModeID)
            for control in controls {
                guard let source = byLabel[control.id],          // a diamond face control
                      profile.mapping[control.id] == nil         // still Default (not user-overridden)
                else { continue }
                overrides.append(Override(driver: control.driver, sources: [source]))
            }
        }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/NintendoLayoutTests`
Expected: PASS.

- [ ] **Step 7: Run the full suite (no regressions)**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add WaveBird/HID/MappingControls.swift WaveBird/Profiles/MappingProfile.swift WaveBirdTests/MappingTests.swift
git commit -m "feat: Nintendo button-layout default (model + resolve)" \
  -m "Per-profile useNintendoLayout injects by-label face-button defaults for
Xbox (a<-A, b<-B, x<-X, y<-Y) for non-overridden rows; no-op for switchPro
and PlayStation. User overrides always win." \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Editor toggle

**Files:**
- Modify: `WaveBird/UI/ProfileDetailPane.swift`

**Interfaces:**
- Consumes: `MappingControls.nintendoLayoutSources(forModeID:)`, `draft.useNintendoLayout`, existing `commit()`, `isReadOnly`.
- Produces: no new API.

- [ ] **Step 1: Add the conditional toggle at the top of the Buttons section**

In `body`, inside `Section("Buttons") { … }`, add this as the first child (before the `ForEach(MappingControls.controls(...))`):

```swift
                if !MappingControls.nintendoLayoutSources(forModeID: draft.baseModeID).isEmpty {
                    Toggle("Use Nintendo Button Layout", isOn: Binding(
                        get: { draft.useNintendoLayout },
                        set: { draft.useNintendoLayout = $0; commit() }
                    ))
                    .disabled(isReadOnly)
                }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run the suite (no regressions)**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add WaveBird/UI/ProfileDetailPane.swift
git commit -m "feat: Use Nintendo Button Layout toggle in profile editor" \
  -m "Shown at the top of the Buttons section only for modes with a by-label
map (Xbox today); disabled on read-only built-ins." \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: HARDWARE CHECKPOINT**

Not automatable. Verify on real controllers: (a) a GameCube on a custom Xbox profile with the toggle ON → A→A, B→B, X→X, Y→Y in a consuming app; (b) a Switch Pro / Joy-Con with the toggle OFF → positional unchanged (bottom face button = Xbox A); (c) an overridden face row is unaffected by the toggle. Note results in the commit/PR.

---

## Self-Review

**Spec coverage:**
- §1 Profile field → Task 1 Step 4. ✓
- §2 Per-mode by-label map → Task 1 Step 3. ✓
- §3 Resolve injection (non-overridden face rows only) → Task 1 Step 5 + `userOverrideWinsOverToggle` test. ✓
- §4 Conditional UI toggle → Task 2. ✓
- §5 Case resolution (Xbox on/off, switchPro/PS no-op) → `toggleInjectsByLabelDefaultsForXbox`, `toggleIsNoOpForIdentityAndOptedOutModes`. ✓
- Testing section (round-trip/default, injection, override-wins, no-op modes, end-to-end swap) → Task 1 tests. ✓

**Placeholder scan:** none — every step has exact code/commands.

**Type consistency:** `useNintendoLayout`, `nintendoLayoutSources(forModeID:)`, `Override(driver:sources:)`, `MappingSource.button(_:)`, `.sources([...])` match the shipped multi-input model. `resolve` signature unchanged. The `profile.mapping[control.id] == nil` guard relies on `MappingChoice: Equatable` (it is) — but note the guard compares against `nil` (Optional), which needs no `Equatable` on the value.

## Notes

- This is one behavior change split into model+tests (Task 1, unit-verifiable) and UI (Task 2). The hardware checkpoint sits after Task 2.
- PlayStation support later is purely additive: add a `dualShock4`/`dualSense` entry to `MappingControls.nintendoLayout` and the toggle appears and works there with no other change.
