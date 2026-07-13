# Mapping Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reusable, Apple-style mapping profiles (base emulated controller + button mapping) covering GL/GR/SL/SR remapping, per spec `docs/superpowers/specs/2026-07-12-mapping-profiles-design.md`.

**Architecture:** Per-mode `OutputControl` catalogs drive both the editor UI rows and a pure pre-encode `ControllerState` rewrite; encoders are untouched. Profiles persist per-record under `WaveBird.mappingProfiles`; per-controller selection is `KnownController.preferredProfileID` with the legacy `preferredOutputModeID` honored read-only. Live mapping changes flow through per-device `OSAllocatedUnfairLock` spec boxes sampled by the existing dispatch tasks.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI, Swift Testing, CoreHID (untouched).

## Deviations from the spec (decided during planning — flag to reviewer, all three are refinements not scope changes)

1. **`OutputControl` has no `defaultSource` field; Default = copy-through.** The spec assumed each control's default source is a fixed physical button, but shoulder defaults differ per input controller (Pro: bumper ← L button; GC: bumper ← ZL/Z — see `GameCubeProfile.swift:114` vs `ProControllerProfile.swift:223`). A Default row therefore *copies the field the parser already populated* instead of re-reading a named physical button. This also preserves GC analog triggers on Default for free.
2. **Profile IDs are `String`, not `UUID`.** Built-ins use well-known IDs `"default.<modeID>"` (e.g. `default.xboxSeries`); customs use `UUID().uuidString`. One uniform key type for persistence and pickers.
3. **No per-input-profile "available buttons" declaration.** The spec's editor shows the full NS2 union vocabulary regardless of controller, so a hardware-subset list would be dead code. Dropped (YAGNI).

## Global Constraints

- Swift 6.2, strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`. New types default to `nonisolated`; `@MainActor` only for UI/observation types.
- Cross-thread settings reads use the `OSAllocatedUnfairLock<Snapshot>` idiom (see `AxisSettings.swift`) — do not introduce another synchronization style.
- Persisted UserDefaults keys/blobs are user data: `WaveBird.knownControllers` gains only optional fields; `preferredOutputModeID` is never rewritten or removed.
- Every protocol claim cites its source (ndeadly doc section / SDL / BlueRetro / "verified on hardware <date>"). GL/GR/SL/SR bits cite ndeadly `hid_reports.md` and are **unverified on hardware** — say so in comments.
- Both `WaveBird/` and `WaveBirdTests/` are `PBXFileSystemSynchronizedRootGroup`s — new `.swift` files auto-include, no pbxproj edits.
- Build: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
- Test: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
- Commit style: short title (≤72 chars), 2–4 line body, no narrative. End with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Encoders (`buildReport` implementations, descriptors) must not change — default-mapping output stays byte-identical. Anything else touching parsing/HID needs the hardware checklist at the end.

## File Structure

| File | Role |
| --- | --- |
| `WaveBird/Core/ControllerState.swift` (modify) | `ButtonSet.gl` / `.gr` cases |
| `WaveBird/Core/NS2Report0x05.swift` (modify) | GL/GR (Pro) + SL/SR (Joy-Con) bit-table entries |
| `WaveBird/Core/ButtonMapping.swift` (create) | `PhysicalButton`, `MappingChoice`, `ControlDriver`, `OutputControl`, `ResolvedMappingSpec`, `ControllerState.applyingMapping`, `MappingSpecBox` |
| `WaveBird/HID/MappingControls.swift` (create) | Per-mode `OutputControl` catalogs (the UI rows + transform spec) |
| `WaveBird/Profiles/MappingProfile.swift` (create) | `MappingProfile` model + `ResolvedMappingSpec.resolve(profile:)` |
| `WaveBird/Profiles/MappingProfileStore.swift` (create) | `@MainActor @Observable` store: persistence, built-in synthesis, delete |
| `WaveBird/Pairing/KnownController.swift` (modify) | `preferredProfileID` + `resolvedProfileID` |
| `WaveBird/Bridge/DeviceRecord.swift` (modify) | `mappingProfileID` |
| `WaveBird/Bridge/BridgeCoordinator.swift` (modify) | store property, spec boxes, `resolveMappingProfile`, delete/propagate helpers |
| `WaveBird/Bridge/BridgeCoordinator+OutputMode.swift` (modify) | `applyProfile` / `setPreferredProfile` / `activateWithProfile` |
| `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift` (modify) | `.ready` resolution, dispatch sampling, teardown |
| `WaveBird/Bridge/BridgeCoordinator+JoyConPair.swift` (modify) | pair activation by profile, per-pair spec box |
| `WaveBird/Bridge/JoyConPair.swift` (modify) | `mappingProfileID` |
| `WaveBird/UI/ControllerDetailSheet.swift` (modify) | profile picker binding + Manage Profiles link |
| `WaveBird/UI/ProfilePickerSheet.swift` (modify) | first-connect picker lists profiles |
| `WaveBird/UI/ProfilesSettingsTab.swift` (create) | Settings → Profiles list |
| `WaveBird/UI/ProfileEditorSheet.swift` (create) | Apple-style editor sheet |
| `WaveBird/UI/SettingsView.swift` (modify) | add Profiles tab |
| `WaveBird/WaveBirdApp.swift` (modify) | pass coordinator to SettingsView |
| `WaveBirdTests/MappingTests.swift` (create) | all new unit suites |

---

### Task 1: Parse GL/GR (Pro) and SL/SR (Joy-Con)

**Files:**
- Modify: `WaveBird/Core/ControllerState.swift:28-29` (ButtonSet)
- Modify: `WaveBird/Core/NS2Report0x05.swift:61-81` (bit tables)
- Test: `WaveBirdTests/MappingTests.swift` (new file)

**Interfaces:**
- Consumes: existing `ButtonSet` (`rawValue: UInt32`, cases up to `.sr = 1 << 22`), `NS2ButtonBits.decode(_:table:)`, `NS2Report0x05.decode(_:offset:)`.
- Produces: `ButtonSet.gl` (`1 << 23`), `ButtonSet.gr` (`1 << 24`); Pro table decodes wire bits 24/25, Joy-Con tables decode wire bits 4/5 (R) and 20/21 (L). Later tasks read these as ordinary `ButtonSet` members.

- [ ] **Step 1: Write the failing tests**

Create `WaveBirdTests/MappingTests.swift`:

```swift
import Foundation
import Testing
@testable import WaveBird

// Wire-bit decoding for the buttons added by the mapping-profiles feature.
// Bit positions from ndeadly hid_reports.md, Input Report 0x05 → Button Format
// (byte 3: 0x01 = GR, 0x02 = GL; byte 0: 0x10 = SR Right, 0x20 = SL Right;
// byte 2: 0x10 = SR Left, 0x20 = SL Left). Unverified on hardware as of
// 2026-07-12 — see the hardware checklist in the plan.
struct ButtonBitTests {

    @Test func proDecodesGLAndGR() {
        #expect(NS2ButtonBits.decode(1 << 24, table: NS2ButtonBits.pro) == [.gr])
        #expect(NS2ButtonBits.decode(1 << 25, table: NS2ButtonBits.pro) == [.gl])
    }

    @Test func joyConRDecodesSLAndSR() {
        #expect(NS2ButtonBits.decode(1 << 4, table: NS2ButtonBits.joyConR) == [.sr])
        #expect(NS2ButtonBits.decode(1 << 5, table: NS2ButtonBits.joyConR) == [.sl])
    }

    @Test func joyConLDecodesSLAndSR() {
        #expect(NS2ButtonBits.decode(1 << 20, table: NS2ButtonBits.joyConL) == [.sr])
        #expect(NS2ButtonBits.decode(1 << 21, table: NS2ButtonBits.joyConL) == [.sl])
    }

    @Test func fullReportFrameCarriesGrips() {
        // Button field is bytes 4..7 of report 0x05; GL/GR live in byte 7.
        var frame = Data(repeating: 0, count: 62)
        frame[7] = 0x03
        let decoded = NS2Report0x05.decode(frame)
        #expect(decoded != nil)
        let buttons = NS2ButtonBits.decode(decoded!.buttonBits, table: NS2ButtonBits.pro)
        #expect(buttons.contains(.gl))
        #expect(buttons.contains(.gr))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/ButtonBitTests`
Expected: **build failure** — `type 'ButtonSet' has no member 'gl'` (compile error is the failing state here).

- [ ] **Step 3: Implement**

In `WaveBird/Core/ControllerState.swift`, after `static let sr = ButtonSet(rawValue: 1 << 22)` add:

```swift
    static let gl        = ButtonSet(rawValue: 1 << 23)
    static let gr        = ButtonSet(rawValue: 1 << 24)
```

In `WaveBird/Core/NS2Report0x05.swift`, extend the `pro` table (after `Entry(22, .l), Entry(23, .zl),`):

```swift
        // Rear grip buttons GL/GR — byte 3 of the button field, 0x02/0x01.
        // Source: ndeadly hid_reports.md (Report 0x05 Button Format).
        // Unverified on hardware as of 2026-07-12.
        Entry(24, .gr), Entry(25, .gl),
```

Extend `joyConL` (after `Entry(22, .l), Entry(23, .zl),`):

```swift
        // Side-rail SL/SR (Left Joy-Con) — byte 2, 0x20/0x10 per ndeadly
        // hid_reports.md. Unverified on hardware as of 2026-07-12.
        Entry(20, .sr), Entry(21, .sl),
```

Extend `joyConR` (after `Entry(9, .plus), Entry(10, .stickR),`):

```swift
        // Side-rail SL/SR (Right Joy-Con) — byte 0, 0x20/0x10 per ndeadly
        // hid_reports.md. Unverified on hardware as of 2026-07-12.
        Entry(4, .sr), Entry(5, .sl),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/ButtonBitTests`
Expected: `** TEST SUCCEEDED **`, 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Core/ControllerState.swift WaveBird/Core/NS2Report0x05.swift WaveBirdTests/MappingTests.swift
git commit -m "feat: decode GL/GR and SL/SR from report 0x05

Bit positions per ndeadly hid_reports.md Button Format;
unverified on hardware. Pro adds GL/GR, Joy-Con tables add SL/SR.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: PhysicalButton and MappingChoice vocabulary

**Files:**
- Create: `WaveBird/Core/ButtonMapping.swift`
- Test: `WaveBirdTests/MappingTests.swift` (append)

**Interfaces:**
- Consumes: `ButtonSet` members incl. Task 1's `.gl/.gr`.
- Produces: `enum PhysicalButton: String, CaseIterable, Sendable, Codable, Hashable, Identifiable` with `var buttonSetMember: ButtonSet`, `var displayName: String`, `var family: Family`; `enum MappingChoice: RawRepresentable, Codable, Sendable, Hashable` with cases `.off` / `.physical(PhysicalButton)` and `rawValue: String` (`"off"` sentinel). Editor pickers tag on these raw values; `MappingProfile.mapping` values are `MappingChoice`.

- [ ] **Step 1: Write the failing tests** (append to `WaveBirdTests/MappingTests.swift`)

```swift
struct PhysicalButtonTests {

    @Test func rawValuesRoundTrip() {
        for button in PhysicalButton.allCases {
            #expect(PhysicalButton(rawValue: button.rawValue) == button)
        }
    }

    @Test func reservedSentinelsDontCollide() {
        // The editor picker tags "default" and "off" alongside raw values.
        #expect(PhysicalButton(rawValue: "off") == nil)
        #expect(PhysicalButton(rawValue: "default") == nil)
    }

    @Test func gripAndRailMembersMatch() {
        #expect(PhysicalButton.gl.buttonSetMember == .gl)
        #expect(PhysicalButton.gr.buttonSetMember == .gr)
        #expect(PhysicalButton.sl.buttonSetMember == .sl)
        #expect(PhysicalButton.sr.buttonSetMember == .sr)
    }

    @Test func mappingChoiceRawValues() {
        #expect(MappingChoice.off.rawValue == "off")
        #expect(MappingChoice.physical(.gl).rawValue == "gl")
        #expect(MappingChoice(rawValue: "off") == .off)
        #expect(MappingChoice(rawValue: "zl") == .physical(.zl))
        #expect(MappingChoice(rawValue: "nonsense") == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild ... test -only-testing:WaveBirdTests/PhysicalButtonTests`
Expected: build failure — `cannot find 'PhysicalButton' in scope`.

- [ ] **Step 3: Implement**

Create `WaveBird/Core/ButtonMapping.swift`:

```swift
import Foundation
import os

// The Nintendo-side vocabulary a mapping profile's dropdown draws from — the
// union of every supported controller's physical buttons. A profile row
// sourced from a button the connected controller lacks simply never fires.
// Raw values are the persistence format (MappingProfile JSON): never rename.
enum PhysicalButton: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case a, b, x, y
    case l, r, zl, zr
    case plus, minus, home, capture
    case stickL, stickR
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case c
    case gl, gr          // NS2 Pro rear grips
    case z, start        // GameCube
    case sl, sr          // Joy-Con side rails

    var id: String { rawValue }

    // The parsed ButtonSet member that reports this button's press. Note GC's
    // L/R are analog clicks — reading the ButtonSet member means "full click".
    var buttonSetMember: ButtonSet {
        switch self {
        case .a: .a
        case .b: .b
        case .x: .x
        case .y: .y
        case .l: .l
        case .r: .r
        case .zl: .zl
        case .zr: .zr
        case .plus: .plus
        case .minus: .minus
        case .home: .home
        case .capture: .capture
        case .stickL: .stickL
        case .stickR: .stickR
        case .dpadUp: .dpadUp
        case .dpadDown: .dpadDown
        case .dpadLeft: .dpadLeft
        case .dpadRight: .dpadRight
        case .c: .c
        case .gl: .gl
        case .gr: .gr
        case .z: .z
        case .start: .start
        case .sl: .sl
        case .sr: .sr
        }
    }

    // Editor dropdown grouping.
    enum Family: String, CaseIterable, Identifiable {
        case common = "Common"
        case pro = "Pro Controller"
        case gameCube = "GameCube"
        case joyCon = "Joy-Con"
        var id: String { rawValue }
    }

    var family: Family {
        switch self {
        case .gl, .gr: .pro
        case .z, .start: .gameCube
        case .sl, .sr: .joyCon
        default: .common
        }
    }

    var displayName: String {
        switch self {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .l: "L"
        case .r: "R"
        case .zl: "ZL"
        case .zr: "ZR"
        case .plus: "Plus"
        case .minus: "Minus"
        case .home: "Home"
        case .capture: "Capture"
        case .stickL: "Left Stick Click"
        case .stickR: "Right Stick Click"
        case .dpadUp: "D-pad Up"
        case .dpadDown: "D-pad Down"
        case .dpadLeft: "D-pad Left"
        case .dpadRight: "D-pad Right"
        case .c: "C"
        case .gl: "GL"
        case .gr: "GR"
        case .z: "Z"
        case .start: "Start"
        case .sl: "SL"
        case .sr: "SR"
        }
    }
}

// One row's stored choice in a MappingProfile: drive the control from a
// physical button, or disable it outright. Absence from the dict = Default.
enum MappingChoice: RawRepresentable, Codable, Sendable, Hashable {
    case off
    case physical(PhysicalButton)

    var rawValue: String {
        switch self {
        case .off: "off"
        case .physical(let button): button.rawValue
        }
    }

    init?(rawValue: String) {
        if rawValue == "off" {
            self = .off
        } else if let button = PhysicalButton(rawValue: rawValue) {
            self = .physical(button)
        } else {
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild ... test -only-testing:WaveBirdTests/PhysicalButtonTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Core/ButtonMapping.swift WaveBirdTests/MappingTests.swift
git commit -m "feat: add PhysicalButton and MappingChoice vocabulary

String raw values are the profile persistence format; 'off' is the
disable sentinel and must never collide with a button raw value.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: OutputControl catalogs for the four shipping modes

**Files:**
- Modify: `WaveBird/Core/ButtonMapping.swift` (add `ControlDriver`, `OutputControl`)
- Create: `WaveBird/HID/MappingControls.swift`
- Test: `WaveBirdTests/MappingTests.swift` (append)

**Interfaces:**
- Consumes: `ButtonSet`, `PhysicalButton` from Tasks 1–2; `HIDOutputCatalog.allowListIDs`.
- Produces: `enum ControlDriver: Sendable, Hashable` (`.buttons(ButtonSet)`, `.leftBumper`, `.rightBumper`, `.leftTrigger`, `.rightTrigger`); `struct OutputControl: Sendable, Identifiable, Hashable { let id: String; let displayName: String; let driver: ControlDriver }`; `enum MappingControls { static func controls(forModeID:) -> [OutputControl] }`. Task 4's transform iterates these; Task 9's editor renders them as rows.

The drivers below are transcribed from each encoder's reads — do not invent entries; each maps 1:1 to a `contains(...)` / `shoulders.*` read in the named file:

- Xbox: `XboxSeriesOutputProfile.swift:301-328` (report 0x01; the GIP 0x20/0x07 stream reads the same `ControllerState`, so one rewrite covers both).
- DualShock 4: `DualShock4OutputProfile .swift:105-144` (note the space in the filename).
- DualSense: `DualSenseOutputProfile.swift:108-139`.
- Switch Pro: `SwitchProSession.swift:410-497` (both encoder variants read the same fields).

- [ ] **Step 1: Write the failing tests** (append to `MappingTests.swift`)

```swift
struct MappingControlsTests {

    @Test func everyShippingModeHasACatalog() {
        for modeID in HIDOutputCatalog.allowListIDs {
            #expect(!MappingControls.controls(forModeID: modeID).isEmpty,
                    "no control catalog for \(modeID)")
        }
    }

    @Test func controlIDsAreUniqueAndModePrefixed() {
        for modeID in HIDOutputCatalog.allowListIDs {
            let ids = MappingControls.controls(forModeID: modeID).map(\.id)
            #expect(Set(ids).count == ids.count)
            #expect(ids.allSatisfy { $0.hasPrefix("\(modeID).") })
        }
    }

    @Test func debugOnlyModesHaveNoCatalog() {
        // Passthrough bypasses buildReport entirely; mapping is meaningless there.
        #expect(MappingControls.controls(forModeID: "ns2Passthrough").isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild ... test -only-testing:WaveBirdTests/MappingControlsTests`
Expected: build failure — `cannot find 'MappingControls' in scope`.

- [ ] **Step 3: Implement**

Append to `WaveBird/Core/ButtonMapping.swift`:

```swift
// Which canonical ControllerState field an output mode's encoder reads for a
// given control. `.buttons` may carry several ButtonSet members when the
// encoder ORs them (e.g. Xbox Menu reads .plus OR .start) — clearing/setting
// the driver touches all of them together.
enum ControlDriver: Sendable, Hashable {
    case buttons(ButtonSet)
    case leftBumper
    case rightBumper
    case leftTrigger
    case rightTrigger
}

// One remappable row of an output mode: stable ID (persistence key — never
// rename), display name (editor row label), and the driver its encoder reads.
// Default source is copy-through of the driver field, not a stored button:
// shoulder defaults differ per input controller (Pro bumper ← L, GC bumper ←
// ZL), and copy-through also preserves GC's analog triggers on Default.
struct OutputControl: Sendable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let driver: ControlDriver
}
```

Create `WaveBird/HID/MappingControls.swift`:

```swift
import Foundation

// Per-output-mode control catalogs. Each entry mirrors exactly one read in
// that mode's encoder (file:line references in the mapping-profiles plan);
// the catalog is simultaneously the profile editor's row list and the
// pre-encode rewrite's spec. DEBUG-only passthrough modes have no catalog —
// they bypass buildReport, so mapping cannot apply.
enum MappingControls {

    static func controls(forModeID id: String) -> [OutputControl] {
        table[id] ?? []
    }

    private static let table: [String: [OutputControl]] = [
        "xboxSeries": [
            OutputControl(id: "xboxSeries.a",            displayName: "A Button",         driver: .buttons(.b)),
            OutputControl(id: "xboxSeries.b",            displayName: "B Button",         driver: .buttons(.a)),
            OutputControl(id: "xboxSeries.x",            displayName: "X Button",         driver: .buttons(.y)),
            OutputControl(id: "xboxSeries.y",            displayName: "Y Button",         driver: .buttons(.x)),
            OutputControl(id: "xboxSeries.leftBumper",   displayName: "Left Bumper",      driver: .leftBumper),
            OutputControl(id: "xboxSeries.rightBumper",  displayName: "Right Bumper",     driver: .rightBumper),
            OutputControl(id: "xboxSeries.leftTrigger",  displayName: "Left Trigger",     driver: .leftTrigger),
            OutputControl(id: "xboxSeries.rightTrigger", displayName: "Right Trigger",    driver: .rightTrigger),
            OutputControl(id: "xboxSeries.view",         displayName: "View",             driver: .buttons(.minus)),
            OutputControl(id: "xboxSeries.menu",         displayName: "Menu",             driver: .buttons([.plus, .start])),
            OutputControl(id: "xboxSeries.guide",        displayName: "Guide",            driver: .buttons(.home)),
            OutputControl(id: "xboxSeries.share",        displayName: "Share",            driver: .buttons(.capture)),
            OutputControl(id: "xboxSeries.l3",           displayName: "Left Stick Click", driver: .buttons(.stickL)),
            OutputControl(id: "xboxSeries.r3",           displayName: "Right Stick Click", driver: .buttons(.stickR)),
        ],
        "dualShock4": [
            OutputControl(id: "dualShock4.cross",    displayName: "Cross",            driver: .buttons(.b)),
            OutputControl(id: "dualShock4.circle",   displayName: "Circle",           driver: .buttons(.a)),
            OutputControl(id: "dualShock4.square",   displayName: "Square",           driver: .buttons(.y)),
            OutputControl(id: "dualShock4.triangle", displayName: "Triangle",         driver: .buttons(.x)),
            OutputControl(id: "dualShock4.l1",       displayName: "L1",               driver: .leftBumper),
            OutputControl(id: "dualShock4.r1",       displayName: "R1",               driver: .rightBumper),
            OutputControl(id: "dualShock4.l2",       displayName: "L2",               driver: .leftTrigger),
            OutputControl(id: "dualShock4.r2",       displayName: "R2",               driver: .rightTrigger),
            OutputControl(id: "dualShock4.share",    displayName: "Share",            driver: .buttons([.capture, .minus])),
            OutputControl(id: "dualShock4.options",  displayName: "Options",          driver: .buttons([.start, .plus])),
            OutputControl(id: "dualShock4.l3",       displayName: "L3",               driver: .buttons(.stickL)),
            OutputControl(id: "dualShock4.r3",       displayName: "R3",               driver: .buttons(.stickR)),
            OutputControl(id: "dualShock4.ps",       displayName: "PS Button",        driver: .buttons(.home)),
            OutputControl(id: "dualShock4.touchpad", displayName: "Touchpad Click",   driver: .buttons(.c)),
        ],
        "dualSense": [
            OutputControl(id: "dualSense.cross",    displayName: "Cross",             driver: .buttons(.b)),
            OutputControl(id: "dualSense.circle",   displayName: "Circle",            driver: .buttons(.a)),
            OutputControl(id: "dualSense.square",   displayName: "Square",            driver: .buttons(.y)),
            OutputControl(id: "dualSense.triangle", displayName: "Triangle",          driver: .buttons(.x)),
            OutputControl(id: "dualSense.l1",       displayName: "L1",                driver: .leftBumper),
            OutputControl(id: "dualSense.r1",       displayName: "R1",                driver: .rightBumper),
            OutputControl(id: "dualSense.l2",       displayName: "L2",                driver: .leftTrigger),
            OutputControl(id: "dualSense.r2",       displayName: "R2",                driver: .rightTrigger),
            OutputControl(id: "dualSense.create",   displayName: "Create",            driver: .buttons([.capture, .minus])),
            OutputControl(id: "dualSense.options",  displayName: "Options",           driver: .buttons([.start, .plus])),
            OutputControl(id: "dualSense.l3",       displayName: "L3",                driver: .buttons(.stickL)),
            OutputControl(id: "dualSense.r3",       displayName: "R3",                driver: .buttons(.stickR)),
            OutputControl(id: "dualSense.ps",       displayName: "PS Button",         driver: .buttons(.home)),
            OutputControl(id: "dualSense.touchpad", displayName: "Touchpad Click",    driver: .buttons(.c)),
        ],
        "switchPro": [
            OutputControl(id: "switchPro.a",       displayName: "A",                 driver: .buttons(.a)),
            OutputControl(id: "switchPro.b",       displayName: "B",                 driver: .buttons(.b)),
            OutputControl(id: "switchPro.x",       displayName: "X",                 driver: .buttons(.x)),
            OutputControl(id: "switchPro.y",       displayName: "Y",                 driver: .buttons(.y)),
            OutputControl(id: "switchPro.l",       displayName: "L",                 driver: .leftBumper),
            OutputControl(id: "switchPro.r",       displayName: "R",                 driver: .rightBumper),
            OutputControl(id: "switchPro.zl",      displayName: "ZL",                driver: .leftTrigger),
            OutputControl(id: "switchPro.zr",      displayName: "ZR",                driver: .rightTrigger),
            OutputControl(id: "switchPro.minus",   displayName: "Minus",             driver: .buttons(.minus)),
            OutputControl(id: "switchPro.plus",    displayName: "Plus",              driver: .buttons([.plus, .start])),
            OutputControl(id: "switchPro.home",    displayName: "Home",              driver: .buttons(.home)),
            OutputControl(id: "switchPro.capture", displayName: "Capture",           driver: .buttons(.capture)),
            OutputControl(id: "switchPro.l3",      displayName: "Left Stick Click",  driver: .buttons(.stickL)),
            OutputControl(id: "switchPro.r3",      displayName: "Right Stick Click", driver: .buttons(.stickR)),
        ],
    ]
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild ... test -only-testing:WaveBirdTests/MappingControlsTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Core/ButtonMapping.swift WaveBird/HID/MappingControls.swift WaveBirdTests/MappingTests.swift
git commit -m "feat: add per-mode output control catalogs

Each entry mirrors one encoder read; catalogs double as editor rows
and rewrite spec. DEBUG passthrough modes deliberately have none.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: The mapping transform

**Files:**
- Modify: `WaveBird/Core/ButtonMapping.swift` (add `ResolvedMappingSpec`, `applyingMapping`, `MappingSpecBox`)
- Test: `WaveBirdTests/MappingTests.swift` (append)

**Interfaces:**
- Consumes: `ControlDriver`, `PhysicalButton`, `ControllerState`, `StandardShoulders`.
- Produces: `struct ResolvedMappingSpec: Sendable { struct Override; let overrides: [Override]; var isDefault: Bool; static let identity }` with `enum Source { case off; case physical(PhysicalButton) }`; `ControllerState.applyingMapping(_ spec:) -> ControllerState`; `final class MappingSpecBox: Sendable` with `var current: ResolvedMappingSpec` and `func update(_:)`. Task 5 adds `ResolvedMappingSpec.resolve(profile:)`; Tasks 6–7 sample boxes in dispatch tasks.

- [ ] **Step 1: Write the failing tests** (append to `MappingTests.swift`)

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

    @Test func glDrivesRemappedButton() {
        // "Xbox A ← GL": Xbox A's driver is ButtonSet.b.
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.b), source: .physical(.gl))
        ])
        let pressed = state(buttons: [.gl]).applyingMapping(spec)
        #expect(pressed.buttons.contains(.b))
        // The physical B button no longer drives the remapped control.
        let bOnly = state(buttons: [.b]).applyingMapping(spec)
        #expect(!bOnly.buttons.contains(.b))
        // GL itself passes through untouched (it drives no default control).
        #expect(pressed.buttons.contains(.gl))
    }

    @Test func glDrivesTriggerAsDigitalFullPull() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .leftTrigger, source: .physical(.gl))
        ])
        let pressed = state(buttons: [.gl]).applyingMapping(spec)
        #expect(pressed.shoulders.leftTriggerDigital)
        #expect(pressed.shoulders.leftTriggerAnalog == 0xFF)
        // Original trigger source is cleared when the row is remapped.
        let zl = state(buttons: [.zl],
                       shoulders: StandardShoulders(leftTriggerDigital: true, leftTriggerAnalog: 0xFF))
            .applyingMapping(spec)
        #expect(!zl.shoulders.leftTriggerDigital)
        #expect(zl.shoulders.leftTriggerAnalog == 0)
    }

    @Test func offSuppressesControl() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.home), source: .off)
        ])
        let out = state(buttons: [.home]).applyingMapping(spec)
        #expect(!out.buttons.contains(.home))
    }

    @Test func defaultRowsPreserveAnalogTriggers() {
        // Non-default spec elsewhere; the LT row is untouched, so GC's analog
        // trigger value copies through.
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.b), source: .physical(.gl))
        ])
        let out = state(buttons: [],
                        shoulders: StandardShoulders(leftTriggerAnalog: 0x80)).applyingMapping(spec)
        #expect(out.shoulders.leftTriggerAnalog == 0x80)
    }

    @Test func multiMemberDriverClearsAndSetsTogether() {
        // Xbox Menu reads .plus OR .start; remapping it must silence both.
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons([.plus, .start]), source: .physical(.gr))
        ])
        let startOnly = state(buttons: [.start]).applyingMapping(spec)
        #expect(!startOnly.buttons.contains(.start))
        #expect(!startOnly.buttons.contains(.plus))
        let grPressed = state(buttons: [.gr]).applyingMapping(spec)
        #expect(grPressed.buttons.contains(.plus))
        #expect(grPressed.buttons.contains(.start))
    }

    @Test func onePhysicalButtonMayDriveSeveralControls() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.b), source: .physical(.gl)),
            .init(driver: .rightBumper, source: .physical(.gl)),
        ])
        let out = state(buttons: [.gl]).applyingMapping(spec)
        #expect(out.buttons.contains(.b))
        #expect(out.shoulders.rightBumper)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild ... test -only-testing:WaveBirdTests/MappingTransformTests`
Expected: build failure — `cannot find 'ResolvedMappingSpec' in scope`.

- [ ] **Step 3: Implement** (append to `WaveBird/Core/ButtonMapping.swift`)

```swift
// A profile's mapping compiled against its base mode's control catalog.
// Only non-Default rows become overrides: Default rows need no entry because
// the untouched state already carries the parser's wiring (copy-through).
// Empty overrides == the stock profile — the transform is a guaranteed no-op
// so the default hot path stays bit-exact.
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
    var isDefault: Bool { overrides.isEmpty }

    static let identity = ResolvedMappingSpec(overrides: [])
}

extension ControllerState {
    // Pre-encode rewrite: runs in the dispatch task after invertingY, before
    // buildReport. Reads presses from the ORIGINAL state, writes into a copy —
    // so "A ← ZL" still lets physical ZL drive its own default row too
    // (duplicates allowed, no swap inference).
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
        return out
    }

    private static func clear(_ driver: ControlDriver, in state: inout ControllerState) {
        switch driver {
        case .buttons(let members):
            state.buttons.subtract(members)
        case .leftBumper:
            state.shoulders.leftBumper = false
        case .rightBumper:
            state.shoulders.rightBumper = false
        case .leftTrigger:
            state.shoulders.leftTriggerDigital = false
            state.shoulders.leftTriggerAnalog = 0
        case .rightTrigger:
            state.shoulders.rightTriggerDigital = false
            state.shoulders.rightTriggerAnalog = 0
        }
    }

    private static func set(_ driver: ControlDriver, in state: inout ControllerState) {
        switch driver {
        case .buttons(let members):
            state.buttons.formUnion(members)
        case .leftBumper:
            state.shoulders.leftBumper = true
        case .rightBumper:
            state.shoulders.rightBumper = true
        case .leftTrigger:
            state.shoulders.leftTriggerDigital = true
            state.shoulders.leftTriggerAnalog = 0xFF
        case .rightTrigger:
            state.shoulders.rightTriggerDigital = true
            state.shoulders.rightTriggerAnalog = 0xFF
        }
    }
}

// Live-updatable spec shared between the main actor (profile edits) and a
// device's off-main dispatch task, which samples `current` per report — the
// same lock-guarded-snapshot idiom as AxisSettings/RumbleSettings.
final class MappingSpecBox: Sendable {
    private let lock: OSAllocatedUnfairLock<ResolvedMappingSpec>

    init(_ initial: ResolvedMappingSpec = .identity) {
        lock = OSAllocatedUnfairLock(initialState: initial)
    }

    var current: ResolvedMappingSpec { lock.withLock { $0 } }
    func update(_ spec: ResolvedMappingSpec) { lock.withLock { $0 = spec } }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild ... test -only-testing:WaveBirdTests/MappingTransformTests`
Expected: `** TEST SUCCEEDED **`, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Core/ButtonMapping.swift WaveBirdTests/MappingTests.swift
git commit -m "feat: add mapping rewrite transform and spec box

Overrides clear-then-set their drivers; Default rows copy through,
preserving GC analog triggers. Identity spec is a guaranteed no-op.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: MappingProfile model and store

**Files:**
- Create: `WaveBird/Profiles/MappingProfile.swift`
- Create: `WaveBird/Profiles/MappingProfileStore.swift`
- Test: `WaveBirdTests/MappingTests.swift` (append)

**Interfaces:**
- Consumes: `MappingChoice`, `MappingControls`, `ResolvedMappingSpec`, `HIDOutputCatalog`.
- Produces:
  - `struct MappingProfile: Codable, Sendable, Hashable, Identifiable { var id: String; var name: String; var baseModeID: String; var mapping: [String: MappingChoice] }` plus `var isBuiltIn: Bool` and `static func defaultProfileID(forModeID:) -> String` (returns `"default.<modeID>"`).
  - `ResolvedMappingSpec.resolve(profile: MappingProfile) -> ResolvedMappingSpec`.
  - `@MainActor @Observable final class MappingProfileStore` with `init(catalog: HIDOutputCatalog = .default, defaults: UserDefaults = .standard)`, `private(set) var customProfiles: [MappingProfile]`, `var builtInProfiles: [MappingProfile]`, `func profile(id: String) -> MappingProfile?` (accepts `default.<mode>` IDs, custom IDs, **and bare legacy mode IDs**), `func upsert(_:)`, `func delete(id: String) -> String?` (returns the deleted profile's base-default ID, nil if not found). Persistence: UserDefaults key `WaveBird.mappingProfiles` as `[String: Data]` — one JSON blob per profile so one corrupt record can't take out the rest.

- [ ] **Step 1: Write the failing tests** (append to `MappingTests.swift`)

```swift
struct MappingProfileTests {

    @Test func roundTripsThroughJSON() throws {
        let profile = MappingProfile(
            id: UUID().uuidString,
            name: "Grips as bumpers",
            baseModeID: "xboxSeries",
            mapping: ["xboxSeries.leftBumper": .physical(.gl),
                      "xboxSeries.guide": .off]
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(MappingProfile.self, from: data)
        #expect(decoded == profile)
    }

    @Test func defaultProfileResolvesToIdentity() {
        let profile = MappingProfile(id: MappingProfile.defaultProfileID(forModeID: "xboxSeries"),
                                     name: "Xbox Wireless Controller",
                                     baseModeID: "xboxSeries",
                                     mapping: [:])
        #expect(profile.isBuiltIn)
        #expect(ResolvedMappingSpec.resolve(profile: profile).isDefault)
    }

    @Test func customMappingResolvesOverrides() {
        let profile = MappingProfile(
            id: UUID().uuidString,
            name: "Test",
            baseModeID: "xboxSeries",
            mapping: ["xboxSeries.a": .physical(.gl),
                      "xboxSeries.guide": .off,
                      "xboxSeries.unknownRow": .physical(.gr)]  // stale ID: ignored
        )
        let spec = ResolvedMappingSpec.resolve(profile: profile)
        #expect(spec.overrides.count == 2)
    }
}

@MainActor
struct MappingProfileStoreTests {

    private func makeStore() -> MappingProfileStore {
        let defaults = UserDefaults(suiteName: "MappingProfileStoreTests")!
        defaults.removePersistentDomain(forName: "MappingProfileStoreTests")
        return MappingProfileStore(defaults: defaults)
    }

    @Test func builtInsCoverShippingModes() {
        let store = makeStore()
        let ids = Set(store.builtInProfiles.map(\.baseModeID))
        #expect(HIDOutputCatalog.allowListIDs.isSubset(of: ids))
        #expect(store.builtInProfiles.allSatisfy { $0.isBuiltIn && $0.mapping.isEmpty })
    }

    @Test func upsertPersistsAndReloads() {
        let defaults = UserDefaults(suiteName: "MappingProfileStoreTests")!
        defaults.removePersistentDomain(forName: "MappingProfileStoreTests")
        let store = MappingProfileStore(defaults: defaults)
        let profile = MappingProfile(id: UUID().uuidString, name: "Mine",
                                     baseModeID: "dualSense",
                                     mapping: ["dualSense.l2": .physical(.gl)])
        store.upsert(profile)
        let reloaded = MappingProfileStore(defaults: defaults)
        #expect(reloaded.profile(id: profile.id) == profile)
    }

    @Test func corruptRecordIsDroppedOthersSurvive() throws {
        let defaults = UserDefaults(suiteName: "MappingProfileStoreTests")!
        defaults.removePersistentDomain(forName: "MappingProfileStoreTests")
        let good = MappingProfile(id: "good-id", name: "Good", baseModeID: "switchPro", mapping: [:])
        let dict: [String: Data] = [
            "good-id": try JSONEncoder().encode(good),
            "bad-id": Data("not json".utf8),
        ]
        defaults.set(dict, forKey: MappingProfileStore.defaultsKey)
        let store = MappingProfileStore(defaults: defaults)
        #expect(store.customProfiles.count == 1)
        #expect(store.profile(id: "good-id") != nil)
    }

    @Test func deleteReturnsBaseDefaultFallback() {
        let store = makeStore()
        let profile = MappingProfile(id: UUID().uuidString, name: "Doomed",
                                     baseModeID: "xboxSeries", mapping: [:])
        store.upsert(profile)
        let fallback = store.delete(id: profile.id)
        #expect(fallback == "default.xboxSeries")
        #expect(store.profile(id: profile.id) == nil)
        #expect(store.delete(id: "never-existed") == nil)
    }

    @Test func bareLegacyModeIDResolvesToDefaultProfile() {
        let store = makeStore()
        let profile = store.profile(id: "xboxSeries")
        #expect(profile?.id == "default.xboxSeries")
        #expect(profile?.baseModeID == "xboxSeries")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild ... test -only-testing:WaveBirdTests/MappingProfileTests -only-testing:WaveBirdTests/MappingProfileStoreTests`
Expected: build failure — `cannot find 'MappingProfile' in scope`.

- [ ] **Step 3: Implement**

Create `WaveBird/Profiles/MappingProfile.swift`:

```swift
import Foundation

// A named, reusable button mapping with a fixed base emulated controller.
// Built-ins ("Default Xbox …") are synthesized from the output catalog under
// well-known IDs and never stored; customs persist via MappingProfileStore.
// `mapping` is sparse: absent control ID = Default (copy-through wiring).
struct MappingProfile: Codable, Sendable, Hashable, Identifiable {
    var id: String            // "default.<modeID>" for built-ins; UUID string for customs
    var name: String
    var baseModeID: String    // HIDOutputCatalog entry ID; fixed after creation
    var mapping: [String: MappingChoice] = [:]

    static let defaultIDPrefix = "default."

    static func defaultProfileID(forModeID modeID: String) -> String {
        defaultIDPrefix + modeID
    }

    var isBuiltIn: Bool { id.hasPrefix(Self.defaultIDPrefix) }
}

extension ResolvedMappingSpec {
    // Compile a profile against its base mode's control catalog. Entries whose
    // control ID isn't in the catalog (stale data from a future version) are
    // ignored rather than failing the whole profile.
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
        return ResolvedMappingSpec(overrides: overrides)
    }
}
```

Create `WaveBird/Profiles/MappingProfileStore.swift`:

```swift
import Foundation
import Observation

// Owns the user's custom mapping profiles and synthesizes the built-in
// defaults from the output catalog. Persists one JSON blob per profile under
// a single UserDefaults dictionary key so one corrupt record is dropped
// without losing the rest (decode-with-recovery per the design spec).
@MainActor
@Observable
final class MappingProfileStore {
    static let defaultsKey = "WaveBird.mappingProfiles"

    private let catalog: HIDOutputCatalog
    private let defaults: UserDefaults
    private(set) var customProfiles: [MappingProfile] = []

    init(catalog: HIDOutputCatalog = .default, defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.defaults = defaults
        load()
    }

    // One read-only default per catalog entry (DEBUG-only modes included in
    // DEBUG builds automatically — the catalog only contains them there).
    var builtInProfiles: [MappingProfile] {
        catalog.entries.compactMap { builtInProfile(forModeID: $0.id) }
    }

    // Accepts well-known default IDs, custom IDs, and bare legacy output-mode
    // IDs (pre-profiles preferredOutputModeID values resolve to that mode's
    // default profile — migration by interpretation, never rewriting).
    func profile(id: String) -> MappingProfile? {
        if let custom = customProfiles.first(where: { $0.id == id }) { return custom }
        if id.hasPrefix(MappingProfile.defaultIDPrefix) {
            let modeID = String(id.dropFirst(MappingProfile.defaultIDPrefix.count))
            return builtInProfile(forModeID: modeID)
        }
        return builtInProfile(forModeID: id)
    }

    func upsert(_ profile: MappingProfile) {
        guard !profile.isBuiltIn else { return }
        customProfiles.removeAll { $0.id == profile.id }
        customProfiles.append(profile)
        customProfiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    // Removes a custom profile. Returns the well-known ID of its base mode's
    // default profile so the coordinator can rewrite references (same VHID
    // identity, stock mapping), or nil if the ID wasn't a stored custom.
    func delete(id: String) -> String? {
        guard let victim = customProfiles.first(where: { $0.id == id }) else { return nil }
        customProfiles.removeAll { $0.id == id }
        persist()
        return MappingProfile.defaultProfileID(forModeID: victim.baseModeID)
    }

    private func builtInProfile(forModeID modeID: String) -> MappingProfile? {
        guard let entry = catalog.entry(id: modeID) else { return nil }
        return MappingProfile(id: MappingProfile.defaultProfileID(forModeID: modeID),
                              name: entry.displayName,
                              baseModeID: modeID)
    }

    private func load() {
        guard let dict = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data] else { return }
        customProfiles = dict.values
            .compactMap { try? JSONDecoder().decode(MappingProfile.self, from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func persist() {
        var dict: [String: Data] = [:]
        for profile in customProfiles {
            dict[profile.id] = try? JSONEncoder().encode(profile)
        }
        defaults.set(dict, forKey: Self.defaultsKey)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild ... test -only-testing:WaveBirdTests/MappingProfileTests -only-testing:WaveBirdTests/MappingProfileStoreTests`
Expected: `** TEST SUCCEEDED **`, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Profiles/MappingProfile.swift WaveBird/Profiles/MappingProfileStore.swift WaveBirdTests/MappingTests.swift
git commit -m "feat: add MappingProfile model and store

Per-record JSON persistence with decode-with-recovery; built-ins
synthesized from the catalog; bare mode IDs resolve as legacy input.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Coordinator — solo resolution, spec boxes, dispatch sampling

No new unit tests (the coordinator is `@MainActor` and CoreBluetooth-coupled; the repo deliberately doesn't mock OS types). Verification = full build + existing suites green.

**Files:**
- Modify: `WaveBird/Pairing/KnownController.swift`
- Modify: `WaveBird/Bridge/DeviceRecord.swift:20-41`
- Modify: `WaveBird/Bridge/BridgeCoordinator.swift`
- Modify: `WaveBird/Bridge/BridgeCoordinator+OutputMode.swift`
- Modify: `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift`

**Interfaces:**
- Consumes: Tasks 2–5 types.
- Produces (used by Tasks 7–9):
  - `KnownController.preferredProfileID: String?` and `var resolvedProfileID: String?`
  - `DeviceRecord.mappingProfileID: String?`
  - `BridgeCoordinator.mappingProfiles: MappingProfileStore`
  - `func resolveMappingProfile(id: String?) -> MappingProfile`
  - `func seedMappingSpec(for id: DeviceID, profile: MappingProfile)`
  - `func applyProfile(_ profileID: String, for id: DeviceID) async`
  - `func setPreferredProfile(_ profileID: String, forSerial serial: String) async`
  - `activateWithProfile(_ profileID: String, for id: DeviceID) async` (same name, parameter is now a profile ID; bare mode IDs still resolve)
  - Transitional wrappers `setOutputMode` / `setPreferredOutputMode` kept so the UI still compiles; removed in Task 8.

- [ ] **Step 1: `KnownController` fields**

In `WaveBird/Pairing/KnownController.swift`, after `var preferredOutputModeID: String? = nil` add:

```swift
    // Per-serial mapping-profile selection ("default.<modeID>" or a custom
    // profile's UUID string). Optional so pre-profiles blobs still decode.
    // When nil, preferredOutputModeID (the pre-profiles field, never rewritten
    // or removed — downgrades keep working) is interpreted as that mode's
    // default profile via resolvedProfileID.
    var preferredProfileID: String? = nil
```

And after the struct's last property add:

```swift
    // The profile selection to honor: the new field wins; the legacy mode
    // preference is read as its default profile (migration by interpretation).
    var resolvedProfileID: String? {
        preferredProfileID
            ?? preferredOutputModeID.map { MappingProfile.defaultProfileID(forModeID: $0) }
    }
```

- [ ] **Step 2: `DeviceRecord` field**

In `WaveBird/Bridge/DeviceRecord.swift`, after `var outputModeID: String` add:

```swift
    // The mapping profile currently selected for this connection. outputModeID
    // stays the profile's BASE mode (it drives VHID identity everywhere);
    // this ID is what pickers display and what spec boxes are seeded from.
    var mappingProfileID: String? = nil
```

- [ ] **Step 3: Coordinator storage + helpers**

In `WaveBird/Bridge/BridgeCoordinator.swift`:

After `let catalog: HIDOutputCatalog` add:

```swift
    let mappingProfiles: MappingProfileStore
```

In `init`, after `self.catalog = catalog` add:

```swift
        self.mappingProfiles = MappingProfileStore(catalog: catalog)
```

After the `xboxOutputSettingsBySerial` block add:

```swift
    // Per-device live mapping specs, sampled by the off-main dispatch tasks
    // (same lock-guarded-snapshot idiom as rumble/axis settings). Seeded at
    // profile resolution; updated in place on profile edits so a live change
    // applies without restarting the dispatch task or republishing.
    @ObservationIgnored
    var mappingSpecBoxes: [DeviceID: MappingSpecBox] = [:]

    // The single Joy-Con pair's spec box (one pair at a time, like the pair
    // itself). Reset to .identity on pair teardown.
    @ObservationIgnored
    let pairMappingSpecBox = MappingSpecBox()

    // Never returns nil: dangling/unknown IDs (deleted profile, DEBUG-only
    // mode in a release build) fall back to the default profile of the
    // global default mode — same degradation as catalog.resolved.
    func resolveMappingProfile(id: String?) -> MappingProfile {
        if let id, let profile = mappingProfiles.profile(id: id) { return profile }
        return mappingProfiles.profile(id: MappingProfile.defaultProfileID(forModeID: defaultOutputModeID))
            ?? MappingProfile(id: MappingProfile.defaultProfileID(forModeID: defaultOutputModeID),
                              name: defaultOutputModeID,
                              baseModeID: defaultOutputModeID)
    }

    func seedMappingSpec(for id: DeviceID, profile: MappingProfile) {
        let spec = ResolvedMappingSpec.resolve(profile: profile)
        if let box = mappingSpecBoxes[id] {
            box.update(spec)
        } else {
            mappingSpecBoxes[id] = MappingSpecBox(spec)
        }
    }
```

- [ ] **Step 4: `+OutputMode` — profile-based activation**

In `WaveBird/Bridge/BridgeCoordinator+OutputMode.swift`, replace `activateWithProfile` (lines 9–52) with:

```swift
    // Called by ProfilePickerSheet when the user confirms their choice.
    // `profileID` may be a well-known default ID, a custom profile ID, or (for
    // legacy callers) a bare output-mode ID — resolveMappingProfile handles all.
    func activateWithProfile(_ profileID: String, for id: DeviceID) async {
        guard let record = devices[id], record.awaitingProfileSelection else { return }
        let profile = resolveMappingProfile(id: profileID)
        devices[id]?.awaitingProfileSelection = false
        devices[id]?.outputModeID = profile.baseModeID
        devices[id]?.mappingProfileID = profile.id

        if let pair = joyConPair, pair.includes(id) {
            // Task 7 converts activateJoyConPair to profile IDs; until then
            // route the base mode so the merged VHID still comes up right.
            await activateJoyConPair(modeID: profile.baseModeID)
            advanceAwaitingProfileSelection()
            return
        }

        if let serial = record.serial {
            if knownControllers[serial] != nil {
                await setPreferredProfile(profile.id, forSerial: serial)
            } else {
                pendingProfileIDs[serial] = profile.id
                let onDevicePaired = HostAdapter.address().flatMap { record.onDeviceHostAddresses?.contains($0) } ?? false
                recordController(for: record, isPaired: onDevicePaired)
            }
        }
        seedMappingSpec(for: id, profile: profile)
        guard let r = devices[id] else { return }
        if let (vhid, session) = makeVirtualHID(for: r, modeID: profile.baseModeID) {
            await vhid.activate()
            devices[id]?.virtualHID = vhid
            devices[id]?.session = session
            devices[id]?.activeOutputModeID = profile.baseModeID
            startDispatch(for: id)
            await applySecondaryInputs(for: id, modeID: profile.baseModeID)
        } else {
            await failVirtualHID(for: id)
            advanceAwaitingProfileSelection()
            return
        }
        if let updated = devices[id] {
            maybePromptForPairing(record: updated)
        }
        advanceAwaitingProfileSelection()
    }
```

Replace `setPreferredOutputMode` (lines 63–73) and `setOutputMode` (lines 116–122) with:

```swift
    // Persist the per-serial profile selection (normalized to a real profile
    // ID) and apply it live if the controller is connected. The legacy
    // preferredOutputModeID is left untouched for downgrade safety.
    func setPreferredProfile(_ profileID: String, forSerial serial: String) async {
        let profile = resolveMappingProfile(id: profileID)
        guard var paired = knownControllers[serial] else { return }
        if paired.preferredProfileID != profile.id {
            paired.preferredProfileID = profile.id
            knownControllers[serial] = paired
            persistKnownControllers()
        }
        if let liveID = devices.first(where: { $0.value.serial == serial })?.key {
            await applyProfile(profile.id, for: liveID)
        }
    }

    // Apply a profile to a live connection. Same base = spec-box swap only
    // (no republish, applies mid-session); different base = the existing
    // republish path with the new VHID identity.
    func applyProfile(_ profileID: String, for id: DeviceID) async {
        let profile = resolveMappingProfile(id: profileID)
        if let pair = joyConPair, pair.includes(id) {
            await activateJoyConPair(modeID: profile.baseModeID)  // Task 7: profile-aware
            return
        }
        devices[id]?.mappingProfileID = profile.id
        seedMappingSpec(for: id, profile: profile)
        guard devices[id]?.outputModeID != profile.baseModeID else { return }
        devices[id]?.outputModeID = profile.baseModeID
        UserDefaults.standard.set(profile.baseModeID, forKey: BridgeCoordinator.outputModeDefaultsKey)
        guard devices[id]?.virtualHID != nil else { return }
        await republishVirtualHID(for: id, modeID: profile.baseModeID)
    }

    // Transitional shims so ControllerDetailSheet still compiles until Task 8
    // rewires it. Bare mode IDs resolve to that mode's default profile.
    func setPreferredOutputMode(_ modeID: String, forSerial serial: String) async {
        await setPreferredProfile(modeID, forSerial: serial)
    }

    func setOutputMode(_ modeID: String, for id: DeviceID) async {
        await applyProfile(modeID, for: id)
    }
```

In `recordController` (line 78), change the `preferredOutputModeID:` argument line and add the new field:

```swift
            preferredOutputModeID: knownControllers[serial]?.preferredOutputModeID,
            preferredProfileID: knownControllers[serial]?.preferredProfileID ?? pendingProfileIDs[serial],
            isPaired: isPaired
```

(Note: `KnownController`'s memberwise init gains `preferredProfileID` between `preferredOutputModeID` and `isPaired` because of property order — keep the declaration order from Step 1.)

In `dismissProfilePicker`, change the fallback to an explicit default-profile ID:

```swift
    func dismissProfilePicker() async {
        guard let id = awaitingProfileSelectionID else { return }
        await activateWithProfile(MappingProfile.defaultProfileID(forModeID: defaultOutputModeID), for: id)
    }
```

- [ ] **Step 5: Rename `pendingProfileModeIDs`**

In `WaveBird/Bridge/BridgeCoordinator.swift:98`, rename the property (it now stores profile IDs):

```swift
    // Holds the profile ID chosen in ProfilePickerSheet for controllers whose
    // KnownController entry doesn't exist yet at selection time. Consumed by
    // recordController so the preference survives the pairing exchange.
    @ObservationIgnored
    var pendingProfileIDs: [String: String] = [:]
```

Fix all references (`grep -rn pendingProfileModeIDs WaveBird/` → `BridgeCoordinator.swift`, `BridgeCoordinator+OutputMode.swift`; possibly `+Pairing.swift`).

- [ ] **Step 6: `.ready` resolution + dispatch sampling + teardown**

In `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift`, in the `.ready` case, replace the known-preference branch (lines 173–192) with:

```swift
            if let serial = record.serial,
               let preferredID = knownControllers[serial]?.resolvedProfileID {
                // Known preference — resolve the profile, seed the mapping
                // spec, and create the VHID for its base mode immediately.
                let profile = resolveMappingProfile(id: preferredID)
                devices[id]?.outputModeID = profile.baseModeID
                devices[id]?.mappingProfileID = profile.id
                seedMappingSpec(for: id, profile: profile)
                if let r = devices[id], let (vhid, session) = makeVirtualHID(for: r, modeID: profile.baseModeID) {
                    await vhid.activate()
                    devices[id]?.virtualHID = vhid
                    devices[id]?.session = session
                    devices[id]?.activeOutputModeID = profile.baseModeID
                    startDispatch(for: id)
                    await applySecondaryInputs(for: id, modeID: profile.baseModeID)
                } else {
                    if let r = devices[id] { refreshKnownController(for: r) }
                    await failVirtualHID(for: id)
                    return
                }
                if let updated = devices[id] {
                    refreshKnownController(for: updated)
                    maybePromptForPairing(record: updated)
                }
            } else {
```

In `startDispatch` (line 13), after `let axis = axisSettings(for: record)` add:

```swift
        let mapBox = mappingSpecBoxes[id] ?? {
            let box = MappingSpecBox()
            mappingSpecBoxes[id] = box
            return box
        }()
```

And inside the loop, replace line 40 (`let state = parsed.invertingY(...)`) with:

```swift
                let state = parsed
                    .invertingY(left: inv.invertLeftY, right: inv.invertRightY)
                    .applyingMapping(mapBox.current)
```

In the `.disconnected` case, alongside `rumbleRefreshBoxes[id] = nil` (line 253) add:

```swift
            mappingSpecBoxes[id] = nil
```

- [ ] **Step 7: Build + full existing tests**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`. If `persistPairPreference`/Joy-Con files fail on `KnownController`'s memberwise init (new parameter), add `preferredProfileID: nil,` after the `preferredOutputModeID: nil,` argument there — Task 7 rewrites that function anyway.

Run: `xcodebuild ... test -only-testing:WaveBirdTests`
Expected: `** TEST SUCCEEDED **` (all suites incl. pairing vectors and stick mapping).

- [ ] **Step 8: Commit**

```bash
git add -A WaveBird/ WaveBirdTests/
git commit -m "feat: resolve mapping profiles in the solo pipeline

KnownController.preferredProfileID (legacy mode ID honored read-only),
per-device spec boxes sampled in dispatch, applyProfile swaps spec
without republish when the base mode is unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Joy-Con pair path, delete-in-use, live propagation

**Files:**
- Modify: `WaveBird/Bridge/JoyConPair.swift`
- Modify: `WaveBird/Bridge/BridgeCoordinator+JoyConPair.swift`
- Modify: `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift` (`startPairDispatch`)
- Modify: `WaveBird/Bridge/BridgeCoordinator.swift` (propagation/delete/count helpers)
- Modify: `WaveBird/Bridge/BridgeCoordinator+OutputMode.swift` (pair branches → profile IDs)

**Interfaces:**
- Consumes: Task 6's helpers.
- Produces:
  - `JoyConPair.mappingProfileID: String?`
  - `activateJoyConPair(profileID: String) async` (replaces `activateJoyConPair(modeID:)`)
  - `persistPairPreference(profileID: String, forSerial: String, record: DeviceRecord)`
  - `func mappingProfileDidChange(_ profileID: String)` — editor Done hook (Task 9)
  - `func deleteMappingProfile(_ profileID: String) async` — Settings delete hook (Task 9)
  - `func assignedControllerCount(profileID: String) -> Int` — Settings list subtitle (Task 9)

- [ ] **Step 1: `JoyConPair` field**

In `WaveBird/Bridge/JoyConPair.swift`, next to `activeOutputModeID` add (match the class's existing property style):

```swift
    // Mapping profile driving the merged VHID (activeOutputModeID stays the
    // base mode). Set in activateJoyConPair, cleared on teardown.
    var mappingProfileID: String? = nil
```

- [ ] **Step 2: Pair activation by profile**

In `WaveBird/Bridge/BridgeCoordinator+JoyConPair.swift`:

Change `activateJoyConPair(modeID: String)` to `activateJoyConPair(profileID: String)`. At the top of the body, after the `guard`, insert:

```swift
        let profile = resolveMappingProfile(id: profileID)
        let modeID = profile.baseModeID
```

Change the two persist calls to:

```swift
        if let serial = left.serial { persistPairPreference(profileID: profile.id, forSerial: serial, record: left) }
        if let serial = right.serial { persistPairPreference(profileID: profile.id, forSerial: serial, record: right) }
```

After `pair.activeOutputModeID = modeID` add:

```swift
        pair.mappingProfileID = profile.id
        pairMappingSpecBox.update(ResolvedMappingSpec.resolve(profile: profile))
```

(The rest of the body — VHID creation, `startPairDispatch`, pairing prompts — is unchanged; it already uses the local `modeID`.)

Rewrite `persistPairPreference` to write the new field and leave the legacy one alone:

```swift
    // Persist the user's profile choice on each Joy-Con serial individually so
    // either side reconnecting alone restores the same profile once paired up.
    func persistPairPreference(profileID: String, forSerial serial: String, record: DeviceRecord) {
        let onDevicePaired = HostAdapter.address().flatMap { record.onDeviceHostAddresses?.contains($0) } ?? false
        var entry = knownControllers[serial] ?? KnownController(
            serial: serial,
            productID: record.advertisement.productID,
            displayName: record.profile.name,
            lastSeenAt: Date(),
            peripheralUUID: record.id.raw,
            preferredOutputModeID: nil,
            preferredProfileID: nil,
            isPaired: onDevicePaired
        )
        entry.preferredProfileID = profileID
        entry.lastSeenAt = Date()
        entry.peripheralUUID = record.id.raw
        knownControllers[serial] = entry
        persistKnownControllers()
    }
```

In `formJoyConPair`, replace the stored-preference lookup and call:

```swift
        let storedProfileID: String? = left.serial.flatMap { knownControllers[$0]?.resolvedProfileID }
            ?? right.serial.flatMap { knownControllers[$0]?.resolvedProfileID }

        if let storedProfileID {
            await activateJoyConPair(profileID: storedProfileID)
        } else {
```

In `promoteSoloJoyCon`, replace the stored-preference branch body (lines 79–96) with the profile-resolved version:

```swift
        if let serial = record.serial,
           let preferredID = knownControllers[serial]?.resolvedProfileID {
            let profile = resolveMappingProfile(id: preferredID)
            devices[id]?.outputModeID = profile.baseModeID
            devices[id]?.mappingProfileID = profile.id
            seedMappingSpec(for: id, profile: profile)
            if let r = devices[id], let (vhid, session) = makeVirtualHID(for: r, modeID: profile.baseModeID) {
                await vhid.activate()
                devices[id]?.virtualHID = vhid
                devices[id]?.session = session
                devices[id]?.activeOutputModeID = profile.baseModeID
                startDispatch(for: id)
                if let updated = devices[id] {
                    maybePromptForPairing(record: updated)
                }
            } else {
                await failVirtualHID(for: id)
            }
        } else {
```

In `tearDownJoyConPair`, before `joyConPair = nil` add:

```swift
        pairMappingSpecBox.update(.identity)
```

- [ ] **Step 3: Pair dispatch sampling**

In `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift`, `startPairDispatch` (line 72): after `let axis = pairAxisSettings()` add:

```swift
        let mapBox = pairMappingSpecBox
```

Replace line 101 with:

```swift
                let mapped = merged
                    .invertingY(left: inv.invertLeftY, right: inv.invertRightY)
                    .applyingMapping(mapBox.current)
                let report = await session.buildReport(mapped)
```

- [ ] **Step 4: Update the two Task-6 pair shims**

In `BridgeCoordinator+OutputMode.swift`, both pair branches (`activateWithProfile` and `applyProfile`) currently call `activateJoyConPair(modeID: profile.baseModeID)`. Change both to:

```swift
            await activateJoyConPair(profileID: profile.id)
```

- [ ] **Step 5: Propagation, delete-in-use, assignment count** (append to `BridgeCoordinator.swift`)

```swift
    // Push an edited profile's new mapping into every live connection using
    // it. Spec boxes update in place, so no dispatch restart or republish.
    func mappingProfileDidChange(_ profileID: String) {
        guard let profile = mappingProfiles.profile(id: profileID) else { return }
        let spec = ResolvedMappingSpec.resolve(profile: profile)
        for (id, record) in devices where record.mappingProfileID == profileID {
            mappingSpecBoxes[id]?.update(spec)
        }
        if joyConPair?.mappingProfileID == profileID {
            pairMappingSpecBox.update(spec)
        }
    }

    // Delete a custom profile: every reference falls back to its base mode's
    // default profile (same VHID identity, stock mapping).
    func deleteMappingProfile(_ profileID: String) async {
        guard let fallbackID = mappingProfiles.delete(id: profileID) else { return }
        var changed = false
        for (serial, entry) in knownControllers where entry.preferredProfileID == profileID {
            var updated = entry
            updated.preferredProfileID = fallbackID
            knownControllers[serial] = updated
            changed = true
        }
        if changed { persistKnownControllers() }
        for (id, record) in devices where record.mappingProfileID == profileID {
            await applyProfile(fallbackID, for: id)
        }
        if joyConPair?.mappingProfileID == profileID {
            await activateJoyConPair(profileID: fallbackID)
        }
    }

    // "N controllers" subtitle in Settings → Profiles. Counts known
    // controllers whose effective selection is this profile (legacy
    // mode-only records count toward that mode's default profile).
    func assignedControllerCount(profileID: String) -> Int {
        knownControllers.values.count { $0.resolvedProfileID == profileID }
    }
```

- [ ] **Step 6: Build + tests**

Run: build command, then `-only-testing:WaveBirdTests`.
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add WaveBird/Bridge/
git commit -m "feat: profile-aware Joy-Con pair, delete-in-use, live propagation

Pair activation resolves a profile ID and seeds the shared pair spec
box; deleting a profile rewrites references to the base default.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Detail sheet + first-connect picker speak profiles

**Files:**
- Modify: `WaveBird/UI/ControllerDetailSheet.swift` (binding lines 297–313, picker lines 148–168, `iconName` line 315)
- Modify: `WaveBird/UI/ProfilePickerSheet.swift`
- Modify: `WaveBird/Bridge/BridgeCoordinator+OutputMode.swift` (delete the transitional shims)

**Interfaces:**
- Consumes: `coordinator.mappingProfiles` (`builtInProfiles`, `customProfiles`), `resolveMappingProfile`, `setPreferredProfile`, `applyProfile`, `activateWithProfile(profileID:)`, `KnownController.resolvedProfileID`, `DeviceRecord.mappingProfileID`.
- Produces: UI selection values are profile IDs everywhere. No new API.

- [ ] **Step 1: Rewire the detail-sheet binding**

Replace `presentAsBinding` in `ControllerDetailSheet.swift`:

```swift
    // Profile picker binding. Reads prefer the live connection → the paired
    // record's effective selection (legacy mode IDs resolve to that mode's
    // default profile) → the global default's default profile.
    private func profileBinding(live: DeviceRecord?, paired: KnownController?) -> Binding<String> {
        Binding(
            get: {
                live?.mappingProfileID
                    ?? paired?.resolvedProfileID
                    ?? MappingProfile.defaultProfileID(forModeID: coordinator.defaultOutputModeID)
            },
            set: { id in
                if let liveID = live?.id {
                    Task { await coordinator.applyProfile(id, for: liveID) }
                }
                if let serial = paired?.serial ?? live?.serial {
                    Task { await coordinator.setPreferredProfile(id, forSerial: serial) }
                }
            }
        )
    }
```

- [ ] **Step 2: Rewire the picker content + Xbox gating**

Replace the `generalTab` body's picker section and gating:

```swift
    @ViewBuilder
    private func generalTab(live: DeviceRecord?, paired: KnownController?, axis: AxisSettings?, xbox: XboxOutputSettings?) -> some View {
        let binding = profileBinding(live: live, paired: paired)
        let selectedBase = coordinator.resolveMappingProfile(id: binding.wrappedValue).baseModeID
        Form {
            Section {
                LabeledContent("Use profile") {
                    Picker("", selection: binding) {
                        ForEach(coordinator.mappingProfiles.builtInProfiles) { profile in
                            Label(profile.name, systemImage: Self.iconName(forOutputModeID: profile.baseModeID))
                                .tag(profile.id)
                        }
                        if !coordinator.mappingProfiles.customProfiles.isEmpty {
                            Divider()
                            ForEach(coordinator.mappingProfiles.customProfiles) { profile in
                                Label(profile.name, systemImage: Self.iconName(forOutputModeID: profile.baseModeID))
                                    .tag(profile.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                SettingsLink {
                    Text("Manage Profiles…")
                }
            }

            if let axis {
                StickSettingsSection(settings: axis)
            }

            if let xbox, selectedBase == "xboxSeries" {
                XboxAdvancedSection(settings: xbox)
            }
        }
        .formStyle(.grouped)
    }
```

Note: a custom profile whose ID isn't in the picker's tag list (e.g. just deleted) makes SwiftUI log a missing-tag warning and show an empty selection — acceptable; `deleteMappingProfile` rewrites references so it self-heals on the next read.

- [ ] **Step 3: Rewire `ProfilePickerSheet`**

Replace the whole file body logic (keep the visual structure):

```swift
import SwiftUI

struct ProfilePickerSheet: View {
    let coordinator: BridgeCoordinator
    let deviceID: DeviceID
    @State private var selectedProfileID: String

    init(coordinator: BridgeCoordinator, deviceID: DeviceID) {
        self.coordinator = coordinator
        self.deviceID = deviceID
        // Initial selection: the device's current default-profile equivalent,
        // clamped to the allow-list so first-time setup never lands on a
        // DEBUG-only advanced mode.
        let current = coordinator.devices[deviceID]?.outputModeID
        let baseID: String = {
            if let current, HIDOutputCatalog.allowListIDs.contains(current) { return current }
            return coordinator.catalog.firstAllowListedID
        }()
        _selectedProfileID = State(initialValue: MappingProfile.defaultProfileID(forModeID: baseID))
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(displayName)
                    .font(.headline)
                Text("Choose how this controller appears to your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Picker("Profile", selection: $selectedProfileID) {
                ForEach(coordinator.mappingProfiles.builtInProfiles + coordinator.mappingProfiles.customProfiles) { profile in
                    Label {
                        Text(profile.name)
                    } icon: {
                        Image(systemName: iconName(forOutputModeID: profile.baseModeID))
                            .frame(width: 22, alignment: .center)
                    }
                    .padding(.leading, 8)
                    .tag(profile.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Button("Start") {
                Task { await coordinator.activateWithProfile(selectedProfileID, for: deviceID) }
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 320)
    }

    private var displayName: String {
        coordinator.listEntries.first { $0.live?.id == deviceID }?.displayName ?? "Controller"
    }

    private func iconName(forOutputModeID id: String) -> String {
        switch id {
        case "xboxSeries": "xbox.logo"
        case "dualShock4", "dualSense": "playstation.logo"
        default: "gamecontroller.fill"
        }
    }
}
```

- [ ] **Step 4: Delete the transitional shims**

Remove `setPreferredOutputMode(_:forSerial:)` and `setOutputMode(_:for:)` from `BridgeCoordinator+OutputMode.swift` (added in Task 6 Step 4). Grep for remaining callers first: `grep -rn "setOutputMode\|setPreferredOutputMode" WaveBird/` — expected: none after Steps 1–3.

- [ ] **Step 5: Build**

Run: build command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add WaveBird/UI/ControllerDetailSheet.swift WaveBird/UI/ProfilePickerSheet.swift WaveBird/Bridge/BridgeCoordinator+OutputMode.swift
git commit -m "feat: profile-based pickers in detail sheet and first-connect

Use-profile picker lists defaults + customs by profile ID; legacy
mode preferences preselect their default profile. Shims removed.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Settings → Profiles tab and editor sheet

**Files:**
- Create: `WaveBird/UI/ProfileEditorSheet.swift`
- Create: `WaveBird/UI/ProfilesSettingsTab.swift`
- Modify: `WaveBird/UI/SettingsView.swift`
- Modify: `WaveBird/WaveBirdApp.swift:31`

**Interfaces:**
- Consumes: `MappingControls.controls(forModeID:)`, `PhysicalButton` (+ `Family`), `MappingChoice`, `coordinator.mappingProfiles`, `mappingProfileDidChange`, `deleteMappingProfile`, `assignedControllerCount`, `catalog`.
- Produces: `ProfilesSettingsTab(coordinator:)`, `ProfileEditorSheet(coordinator:profile:isNew:onDone:onCancel:)`. `SettingsView` gains a `coordinator: BridgeCoordinator` parameter.

- [ ] **Step 1: Editor sheet** — create `WaveBird/UI/ProfileEditorSheet.swift`:

```swift
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
```

- [ ] **Step 2: Profiles tab** — create `WaveBird/UI/ProfilesSettingsTab.swift`:

```swift
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
```

- [ ] **Step 3: Add the tab + coordinator parameter**

In `WaveBird/UI/SettingsView.swift`: add `let coordinator: BridgeCoordinator` after `@Bindable var launch: LaunchAtLoginService`; inside the `TabView`, after the General tab's `.tabItem { ... }`, add:

```swift
            ProfilesSettingsTab(coordinator: coordinator)
                .tabItem { Label("Profiles", systemImage: "gamecontroller") }
```

Change the frame to fit the list: `.frame(width: 480, height: 400)`.

In `WaveBird/WaveBirdApp.swift:31`:

```swift
            SettingsView(launch: appDelegate.launch, coordinator: appDelegate.coordinator)
```

- [ ] **Step 4: Build + smoke-run**

Run: build command. Expected: `** BUILD SUCCEEDED **`.
Then launch the app (`open` the built product or run from Xcode) and verify without hardware: Settings → Profiles lists four defaults; `+` opens the editor with Name/Emulates/rows; a saved custom appears in Custom and in the detail-sheet picker of any known (offline) controller; deleting it reverts that picker to the base default.

- [ ] **Step 5: Commit**

```bash
git add WaveBird/UI/ WaveBird/WaveBirdApp.swift
git commit -m "feat: Settings Profiles tab with Apple-style editor

Defaults read-only; customs editable with Cancel/Done drafts; delete
falls referencing controllers back to the base default profile.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Full verification + hardware checklist

- [ ] **Step 1: Full test suite**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: `** TEST SUCCEEDED **` — all suites: `StickMappingTests`, `NS2PairingVectorTests`, `ButtonBitTests`, `PhysicalButtonTests`, `MappingControlsTests`, `MappingTransformTests`, `MappingProfileTests`, `MappingProfileStoreTests`.

- [ ] **Step 2: Release-config build check**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Release -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **` (catches DEBUG-only leakage, e.g. accidental references to passthrough modes).

- [ ] **Step 3: Report hardware-validation status**

The build verifies code, not gamepads. State explicitly in the final report that these need a human with controllers (from the spec's checklist):

1. **GL/GR on a real NS2 Pro** — byte 3 · 0x01/0x02 per ndeadly, never read by WaveBird before. **SL/SR on real Joy-Cons**, solo and merged pair.
2. Custom Xbox profile: GL→A visible in hardwaretester.com / Control.app; GL→Left Trigger reads as full analog pull.
3. Default profiles behave identically to today in one known consumer per mode (identity path should make this a formality).
4. Live edit while connected applies without republish; profile switch across bases republishes cleanly; delete-in-use falls back to the base default.
5. Legacy check: a controller whose record has only `preferredOutputModeID` reconnects into that mode's default profile with no prompt.

- [ ] **Step 4: Final commit (if any stragglers) and wrap up**

```bash
git status --short   # expect clean or only the plan checkboxes
```

Use superpowers:finishing-a-development-branch to decide merge/PR next steps.
