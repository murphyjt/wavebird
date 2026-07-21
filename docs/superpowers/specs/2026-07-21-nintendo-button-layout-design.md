# Nintendo Button Layout Toggle

**Date:** 2026-07-21
**Status:** Approved, ready for implementation plan
**Builds on:** `2026-07-12-mapping-profiles-design.md`,
`2026-07-21-multi-input-control-mapping-design.md` (the `MappingProfile`,
`MappingControls`, `ResolvedMappingSpec` / `applyingMapping` pipeline, and the
`MappingSource` source model already shipped).

## Goal

Add a per-profile **"Use Nintendo Button Layout"** toggle that changes the
*default* face-button mapping for output modes whose diamond differs from
Nintendo's — specifically Xbox — from **positional** (Nintendo B → Xbox A) to
**by-label** (Nintendo A → Xbox A). This fixes GameCube→Xbox, where the current
uniform positional swap makes the GameCube A button drive Xbox B.

Non-goals: no wire-protocol, output-catalog-identity, stick-transform, or
multi-input-mapping changes. No PlayStation support (opted out — PS has no
A/B/X/Y labels and the idiomatic convention is ambiguous; the design leaves a
clean extension point). No change to any control other than the four diamond
face buttons.

## Background (current behavior)

- All Nintendo controllers report face buttons by Nintendo **label** into
  `ControllerState.buttons` (wire bit 3 → `.a`, bit 2 → `.b`, bit 1 → `.x`,
  bit 0 → `.y`; identical table for GameCube, Pro, Joy-Con).
- The positional swap lives in the **output catalog** (`MappingControls`),
  uniformly: `xboxSeries.a ← .buttons(.b)`, `.b ← .a`, `.x ← .y`, `.y ← .x`;
  `dualShock4`/`dualSense` swap identically. **`switchPro` is identity**
  (`switchPro.a ← .a`, …) because its diamond matches Nintendo.
- So GameCube A (→ `ButtonSet.a`) drives Xbox **B** today. Only Xbox/PS outputs
  are affected; Switch Pro output is already A→A for every input.

## Design

### 1. Profile field

`MappingProfile` gains:

```swift
var useNintendoLayout: Bool = false
```

Decoded with `decodeIfPresent(...) ?? false` in the existing tolerant
`init(from:)` (added to `CodingKeys`), so existing custom-profile blobs read as
`false` — no regression, no data migration.

### 2. Per-mode by-label face map

A new `MappingControls` lookup returns, per output mode, the Nintendo-**label**
source for each of the four diamond face controls — defined only where the mode
differs from Nintendo:

```swift
static func nintendoLayoutSources(forModeID id: String) -> [String: MappingSource]
// "xboxSeries": ["xboxSeries.a": .button(.a), "xboxSeries.b": .button(.b),
//                "xboxSeries.x": .button(.x), "xboxSeries.y": .button(.y)]
// switchPro (identity) and dualShock4/dualSense (PS, opted out): empty.
```

An **empty** map means the toggle has no effect and is not shown for that mode.
PlayStation support later = add its entry here.

### 3. Resolve — inject by-label defaults for non-overridden face rows

In `ResolvedMappingSpec.resolve(profile:)`, after building overrides from
`profile.mapping` as today, if `profile.useNintendoLayout`:

- For each catalog control whose ID is in the mode's `nintendoLayoutSources`
  **and** is **not** present in `profile.mapping` (i.e. still Default), append
  `Override(driver: control.driver, sources: [byLabelSource])`.

Because a user override for a face row is already in `profile.mapping`, it is
skipped here — **the toggle only changes the Default; explicit overrides always
win.** Nothing but the four face buttons is affected.

Concretely for Xbox with the toggle on and no overrides, four overrides are
injected — e.g. `Override(driver: .buttons(.b), sources: [.button(.a)])` for
`xboxSeries.a` — which `applyingMapping` clears-then-drives so Xbox A reads
Nintendo A (and B←NinB, X←NinX, Y←NinY). The identity fast-path is unaffected:
with the toggle off, nothing is injected.

### 4. UI

In `ProfileDetailPane`, a `Toggle("Use Nintendo Button Layout", …)` at the top
of the **Buttons** section, bound to `draft.useNintendoLayout` and committed
through the existing `commit()`. Shown only when
`!MappingControls.nintendoLayoutSources(forModeID: draft.baseModeID).isEmpty`
(i.e. Xbox today); disabled on read-only built-ins.

### 5. How the cases resolve

- **GameCube → Xbox:** create a custom Xbox profile with the toggle **on** and
  assign it to the GameCube (per-serial `preferredProfileID`, already exists) →
  A→A, B→B, X→X, Y→Y.
- **Switch Pro / Joy-Con → Xbox:** default profile, toggle **off** → positional
  (Nintendo B → Xbox A), unchanged.
- **Anything → Switch Pro:** already A→A; toggle hidden (no-op).

Per-controller behavior comes from per-serial *profile assignment*; a single
profile can't serve both conventions at once (the accepted trade-off of the
per-profile choice).

## Testing

Extend the mapping unit suites (pure functions, no hardware):

- `MappingProfile` JSON round-trips with `useNintendoLayout: true`; a blob
  missing the key decodes to `false`.
- `resolve` with `useNintendoLayout = true` on `xboxSeries`, no overrides →
  injects exactly the four by-label overrides (`.buttons(.b)`←`.button(.a)`,
  etc.); spec is non-default.
- `resolve` with the toggle on but one face row overridden (e.g.
  `xboxSeries.a` → `.sources([.button(.gl)])`) → that row keeps the user
  override; the other three get by-label; no duplicate for `xboxSeries.a`.
- `resolve` with the toggle on for `switchPro` and `dualShock4` → no injection
  (empty map).
- End-to-end `applyingMapping`: with the toggle-on Xbox spec, input Nintendo `.a`
  → output has `.b` set (Xbox A), input `.b` → output has `.a` set (Xbox B).

No UI tests (SwiftUI view, per the project's testing stance).

## Risks / open notes

- Button routing changes, so the Xbox on/off paths need a hardware pass
  (GameCube A→Xbox A with toggle on; Switch-family positional unchanged with
  toggle off).
- Built-in profiles are read-only, so the toggle is usable only on custom
  profiles — a GameCube user must make a custom Xbox profile. Acceptable and
  consistent with how built-ins already work.
