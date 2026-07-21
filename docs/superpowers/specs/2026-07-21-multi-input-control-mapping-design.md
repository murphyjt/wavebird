# Multi-Input Control Mapping

**Date:** 2026-07-21
**Status:** Approved, ready for implementation plan
**Builds on:** `2026-07-12-mapping-profiles-design.md` and
`2026-07-21-profiles-editor-redesign-design.md` (the `MappingProfile` model,
`MappingControls` catalog, `ResolvedMappingSpec` / `applyingMapping` pipeline,
and the profile editor detail pane already shipped).

## Goal

Let one output control be driven by **multiple** physical inputs, OR'd together,
so a single profile can serve several controller form factors — e.g. a "Nintendo"
profile where Right Trigger fires from **Z or ZR**, Menu from **Start or Plus**,
Left Bumper from **L or SL**. Also allow analog trigger travel to be a source so a
trigger→trigger remap stays analog (GameCube L/R analog → an analog-trigger output).

Non-goals: no wire-protocol, output-catalog-identity, or stick-transform changes.
No stick/D-pad remapping changes. No "AND"/chord combining — sources are always OR.

## Constraints (from CLAUDE.md)

- Hardware validation is the bottleneck. Landed as two commits, each flagged for a
  hardware pass: (a) digital multi-source; (b) analog trigger sources.
- The `applyingMapping` identity fast-path (empty overrides + no-op transforms →
  return `self`) stays intact so the default hot path is bit-exact.
- Reuse the existing popover pattern (the stick-transform popover) rather than a
  new UI idiom.

## Design

### 1. Source vocabulary — `MappingSource`

Sources become richer than a bare `PhysicalButton`:

```swift
enum MappingSource: Sendable, Hashable, Codable {
    case button(PhysicalButton)   // digital press (existing vocabulary)
    case leftAnalogTrigger        // shoulders.leftTriggerAnalog  (GameCube travel)
    case rightAnalogTrigger       // shoulders.rightTriggerAnalog
}
```

- `displayName`: `.button` → the button's `displayName`; analog cases →
  "Left Trigger (Analog)" / "Right Trigger (Analog)".
- `family`: `.button` → the button's `Family`; analog cases → `.gameCube`.
- The existing digital `.l`/`.r` remain the trigger **click**; the analog cases are
  the trigger **travel**.

**Which sources are offered per control (driver-dependent):**

- Every control offers all `.button(PhysicalButton.allCases)`, grouped by family.
- **Only** controls whose driver is `.leftTrigger` / `.rightTrigger` additionally
  offer `.leftAnalogTrigger` / `.rightAnalogTrigger`. Analog sources are never
  offered for digital outputs — that deliberately avoids needing an analog→digital
  threshold (approved decision). Digital sources for analog outputs are allowed
  (e.g. "B Button → trigger full-press").

A `ControlDriver.isAnalogTrigger` helper gates this.

### 2. Choice model — explicit multi-source (replace)

```swift
enum MappingChoice: Sendable, Hashable, Codable {
    case off
    case sources([MappingSource])   // non-empty; OR'd; replaces default wiring
}
```

- Absent control ID = **Default** (copy-through), unchanged.
- `.sources` **replaces** the default driver entirely (clear-then-set), matching
  today's single-`.physical` semantics generalized to a set.
- `.sources([])` is never stored — deselecting the last source reverts to Default
  (removes the dict key).

### 3. Resolve + apply — OR combine

`ResolvedMappingSpec.Override` changes from a single `source` to:

```swift
struct Override { let driver: ControlDriver; let sources: [ResolvedSource] }
enum ResolvedSource { case button(PhysicalButton); case leftAnalogTrigger; case rightAnalogTrigger }
```

- `resolve`: `.off` → `Override(driver, sources: [])`; `.sources(list)` →
  `Override(driver, sources: <mapped>)`; absent → no override.
  So **empty `sources` == Off** (clear only); non-empty == replace with the OR.

`applyingMapping` (unchanged outer shape: guard fast-path, clear all overridden
drivers, then drive each):

- **Digital driver** (`.buttons`, `.leftBumper`, `.rightBumper`): set if **any**
  source is pressed. (Only digital sources reach these — see §1 — so no threshold.)
- **Analog trigger driver** (`.leftTrigger` / `.rightTrigger`): analog value =
  **max** over sources, where a pressed button contributes `0xFF` and an analog
  source contributes its live `shoulders.*TriggerAnalog`. Digital flag =
  `(value == 0xFF)` — full press only, so partial analog travel doesn't fake a
  click. This makes trigger→trigger lossless, button→trigger a full press, and the
  max keeps OR semantics ("whichever pushes hardest").

Helper on `ResolvedSource`:

```swift
func isPressed(in: ControllerState) -> Bool       // button: buttonSet member; analog: value > 0
func analogValue(in: ControllerState) -> UInt8    // button: 0xFF/0; analog: the live travel
```

`isPressed` handles analog defensively (`value > 0`) even though analog sources are
never offered to digital drivers.

### 4. UI — per-control popover checklist

The single `Picker` per row becomes a `LabeledContent` whose trailing control is a
pull-down-styled button (summary text + `chevron.up.chevron.down`) that opens a
popover — same pattern as the stick-transform popover.

- Popover top: **Default** row (checkmark when the choice is absent) and **Off** row
  (checkmark when `.off`).
- Divider, then the sources grouped by `Family`, each a checkmark row; analog-trigger
  controls get the extra GameCube analog rows.
- Tapping Default/Off sets that exclusive state. Tapping a source toggles its
  membership and switches the choice to `.sources`; deselecting the last one reverts
  to Default. The popover stays open across multiple toggles.
- Row summary text: absent → "Default"; `.off` → "Off"; one source → its short label
  (displayName minus a trailing " Button"); multiple → those short labels joined
  with " + ", falling back to "N inputs" when the join is long (> 3 sources).
- Presentation state: a single `@State var activeMappingControlID: String?`; each
  row's button binds `isPresented` to `activeMappingControlID == control.id`.
- Read-only (built-in) profiles: the pull-down is disabled, as today.
- Edits commit through the existing `commit()` (upsert + `mappingProfileDidChange`),
  so live propagation is unchanged.

### 5. Persistence

`MappingChoice` gets a custom `Codable`, encoding as an array of string tokens:

- `.off` → `["off"]`; `.sources` → the source tokens.
- `MappingSource` token: `.button(b)` → `b.rawValue`; `.leftAnalogTrigger` →
  `"analogL"`; `.rightAnalogTrigger` → `"analogR"` (tokens no `PhysicalButton`
  rawValue uses).
- Decode: an array containing `"off"` → `.off`; otherwise map tokens to
  `MappingSource`, dropping unknowns; an array that resolves to empty is treated as
  Default (key omitted on next save).

`PhysicalButton` raw values are the persistence format. No `MappingProfile` field
changes — `mapping` stays `[String: MappingChoice]`.

### 6. Work split

**Commit A — digital multi-source** (needs hardware pass for the OR path):
`MappingSource` (button case only wired into UI), `MappingChoice` set model +
array-token `Codable`, `Override.sources` + OR apply for digital drivers and the
button→trigger path, the popover-checklist UI. Existing single-source profiles stay
byte-identical; the new capability is OR of digital buttons.

**Commit B — analog trigger sources** (needs hardware pass on GameCube):
`.leftAnalogTrigger` / `.rightAnalogTrigger`, the `isAnalogTrigger` gating in the
UI, the max-combine + analog value/digital-flag logic, and analog decode tokens.

## Testing

New `MappingApplyTests` (pure functions over bytes/state, no hardware):

- OR of two digital buttons → digital driver set if **either** pressed, cleared if
  neither.
- `.off` → driver cleared; Default (absent) → `applyingMapping` returns `self`
  (fast-path intact).
- Decode round-trips: `["off"]` → `.off`; `["l","sl"]`; `["l","analogL"]`.
- Analog (Commit B): analog trigger driver from an analog source preserves the value
  (input travel 100 → output analog 100); from a digital source → `0xFF`, digital
  flag set; max combine (button `0xFF` vs analog 50 → `0xFF`); partial analog (50) →
  digital flag false.

No UI tests (SwiftUI views, per the project's testing stance).

## Risks / open notes

- The analog-trigger digital flag rule (`value == 0xFF`) is a judgment call;
  confirmed during the Commit B hardware pass (does switchPro ZL from a button
  source register as a full click? does an analog source drive Xbox trigger travel
  smoothly?).
- Summary-text formatting for many sources is cosmetic and may be tuned after
  seeing real profiles.
