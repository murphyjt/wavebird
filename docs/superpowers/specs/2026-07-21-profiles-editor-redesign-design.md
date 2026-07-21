# Profiles Editor Redesign

**Date:** 2026-07-21
**Status:** Approved, ready for implementation plan
**Builds on:** `2026-07-12-mapping-profiles-design.md` (the `MappingProfile` model,
`MappingProfileStore`, and live-propagation path already shipped and are the base
this extends).

## Goal

Replace the modal-sheet Profiles editor (Settings → Profiles) with a Safari-style
master/detail editor, add cosmetic identity to profiles (symbol + tint color),
symbol-ify the mapping rows, and add per-stick input transforms (invert
horizontally / vertically, rotate) that fold in and retire the existing
per-serial Y-axis inversion.

Non-goals: no changes to the wire protocol, output catalog identities, or the
button-remap semantics. D-pad transforms are out of scope for v1 (achievable via
button remaps; may be added later).

## Constraints (from CLAUDE.md)

- Persisted-data compatibility: new profile fields are optional so older JSON
  blobs still decode.
- Hardware-validation is the bottleneck. The stick-transform pipeline change is
  the only piece that alters input bytes; it is committed separately and flagged
  for a hardware pass. The UI restructure keeps the input pipeline byte-identical.
- Reuse the existing `OSAllocatedUnfairLock<Snapshot>` / `MappingSpecBox`
  synchronization idiom rather than introducing a new one.

## Design

### 1. Layout — master/detail replaces the modal

`ProfilesSettingsTab` becomes a two-pane view; `ProfileEditorSheet.swift` is
deleted.

- **Left pane:** `List(selection: $selectedProfileID)` with a **Defaults**
  section and a **Custom** section. Each row shows the profile's tinted symbol +
  name, with an "N controllers" subtitle. `+` / `−` buttons pinned at the bottom
  (Safari style). `−` is disabled for built-in defaults and when no custom
  profile is selected. `+` creates a new custom profile (UUID id) and selects it.
- **Right pane:** the detail form for the selected profile. It live-edits a draft
  that commits through `MappingProfileStore.upsert` + `mappingProfileDidChange`
  on each change (no Done button — matches Safari and the store's existing
  live-propagation support). Built-in defaults render read-only (fields
  disabled, no delete).
- Layout mechanism: a manual `HStack` two-pane, not `NavigationSplitView` (the
  Settings window is fixed-size and split-view fights that). Selection state is
  `@State private var selectedProfileID: String?`. On appear / after add / after
  delete, selection is reconciled to a valid id.

Deleting a custom profile keeps the existing behavior: referencing controllers
fall back to the base mode's default profile (`MappingProfileStore.delete`
already returns that id; `deleteMappingProfile` on the coordinator already
rewrites references). The delete confirmation dialog is preserved.

### 2. Profile metadata — symbol + color

`MappingProfile` gains two optional fields:

```swift
var symbolName: String?   // SF Symbol name from the curated ProfileSymbol list
var colorID: String?      // name into the ProfileColor palette
```

Both optional so pre-existing custom-profile blobs decode unchanged (missing key
→ nil → synthesized default). Built-in defaults never persist these; they
synthesize a per-base default (see below).

- **`ProfileSymbol`** — a new type exposing a plain, extensible list of SF Symbol
  names so more can be dropped in without touching the picker code. A small
  "quick" subset (controller brands: Xbox, PlayStation, Nintendo/Switch, generic
  gamepad) is shown inline; the ellipsis button opens a popover grid of the fuller
  list (joystick, dpad, headset, bolt, star, flag, etc.).
- **`ProfileColor`** — a fixed palette of ~16 named swatches (Safari-like), the
  first being "Automatic" (no explicit tint → use the default). Stored as a
  **name**, not raw RGB, so it stays theme-aware and stable across releases. A
  `ProfileColor` → SwiftUI `Color` resolver lives alongside.
- **Default synthesis:** `MappingProfileStore.builtInProfile(forModeID:)` and a
  new resolver assign each base mode a sensible default symbol + color
  (e.g. `xboxSeries` → xbox.logo / green, `dualShock4`/`dualSense` →
  playstation.logo / blue, `switchPro` → a Nintendo/gamepad glyph / red). Custom
  profiles with nil fields fall back to their base mode's default.

**Where symbol + color surface:** the profiles list rows (left pane) **and** the
"Use profile" picker rows in `ControllerDetailSheet` and the first-connect
picker (`ProfilePickerSheet`), for a consistent identity. A single helper
resolves `(profile) → (symbolName, Color)` and is reused by all three call sites.

### 3. Mapping rows get symbols

Each control row in the detail form becomes `[glyph] Label` (e.g. an A-button
glyph + "A Button") instead of bare text. A static `control-id → SF Symbol` map
covers the catalog (`a.circle`, `dpad`, `l1.rectangle.roundedbottom`,
`zl.rectangle.roundedtop`, stick-click glyphs, etc.). Where no faithful SF Symbol
exists, the row keeps its text label with no glyph — the symbol is an accent, never
the sole signifier, so fallback is graceful. Pure presentation over the existing
`MappingControls` catalog; no model change.

### 4. Stick transforms (behavior-changing)

Per-stick (left / right) transform stored on the profile:

```swift
struct StickTransform: Codable, Sendable, Hashable {
    var invertX: Bool = false
    var invertY: Bool = false
    var rotation: StickRotation = .none   // .none / .cw90 / .deg180 / .ccw90
}
// on MappingProfile:
var leftStick: StickTransform = .init()
var rightStick: StickTransform = .init()
```

All defaulted so old blobs decode to no-op transforms. **Rotate is a
0° / 90° / 180° / 270° picker per stick, not a toggle** — a sideways left Joy-Con
and a sideways right Joy-Con need opposite rotations, so a single toggle can't
serve both.

Transform math on the 12-bit centered `SIMD2<Int16>` sticks (working range
−2047…2047, neutral 0), applied **rotation first, then inversion**:

- `cw90`:  `(x, y) → (y, -x)`
- `deg180`: `(x, y) → (-x, -y)`
- `ccw90`: `(x, y) → (-y, x)`
- then `invertX`: `x → -x`; `invertY`: `y → -y`
- Negation clamps `-(-2048)` cases to the working rail so no overflow past the
  Int16/rail bound (the existing pipeline already treats −2047 as the rail).

The exact rotation direction that yields "up = up" for each Joy-Con orientation
is empirical and confirmed on hardware — the 4-way picker lets the user pick what
works; the code just implements the four rigid transforms correctly.

**Integration — ride the existing `MappingSpecBox`:** these transforms are part
of the resolved mapping. `ResolvedMappingSpec` gains resolved left/right stick
transforms; `ResolvedMappingSpec.resolve(profile:)` fills them from the profile.
The dispatch task already samples `MappingSpecBox.current` per report and calls
`applyingMapping`; transform application happens in that same pass (extend
`applyingMapping`, or add an `applyingStickTransforms` step called adjacent to
it). No new per-device plumbing; live-edit propagation already flows through the
box.

**Retire `AxisSettings`:** the per-serial Y-inversion (`ControllerState.invertingY`,
the `AxisSettings` snapshot sampling in the dispatch task, and the General → Sticks
UI in `ControllerDetailSheet`) is removed. Its role now lives in the profile's
`invertY`.

- **Migration (decision B, approved):** profiles are *shared* across controllers
  while `AxisSettings` is *per-serial*, so there is no faithful 1:1 migration
  (moving a per-serial invert into a shared profile would over-apply it). We
  **drop** the old per-serial Y-inversion on update — remove the
  `WaveBird.axis.<serial>` keys — rather than mis-migrate. It is a single
  re-settable toggle and the app is pre-1.0. This is a deliberate, one-time,
  small data loss, acknowledged.

The `applyingMapping` identity fast-path (empty overrides + no-op transforms →
return `self`) is preserved so the default hot path stays bit-exact.

### 5. Work split

**Phase 1 — pure UI, no hardware needed** (input pipeline byte-identical):
1. Master/detail restructure of `ProfilesSettingsTab`; delete `ProfileEditorSheet`.
2. `ProfileSymbol` + `ProfileColor` types; `symbolName` / `colorID` on
   `MappingProfile`; default synthesis; symbol+color in list rows and both
   "Use profile" pickers.
3. Symbol-ified mapping rows.

**Phase 2 — behavior change, needs a hardware pass** (committed separately, flagged):
4. `StickTransform` / `StickRotation` on `MappingProfile`; extend
   `ResolvedMappingSpec` + `resolve`; apply in the dispatch pass.
5. Retire `AxisSettings` (pipeline, UI, keys) with the drop-migration.

## Testing

- Extend `StickMappingTests` with the four rigid rotations × invert combinations
  as golden-byte cases (rails, sign, neutral-stays-neutral), following the
  existing 12-bit pipeline regression pattern. This is a pure-function test and
  covers the transform math without hardware.
- No new tests for the UI restructure (SwiftUI views, not unit-testable per the
  project's testing stance).
- Phase 2 still needs a hardware pass for feel/orientation confirmation on real
  Joy-Cons; the tests only guard the math.

## Risks / open notes

- SF Symbol availability for some face buttons is imperfect; the design already
  degrades to text-only rows, so this is cosmetic, not blocking.
- Dropping `AxisSettings` data is intentional (decision B).
- Rotation direction semantics are confirmed on hardware during the Phase 2 pass,
  not asserted from code.
