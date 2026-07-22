# Controller List Redesign — Design Spec

**Date:** 2026-07-21
**Branch:** `feature/controller-list-redesign`
**Status:** Approved design, pending spec review

## Goal

Make the main window's controller list read like the macOS System Settings →
Game Controllers pane: a single grouped/inset list, no status dots, no inline
per-row buttons, with a right-click context menu carrying the row actions.

This is a **presentation swap**. The data source (`coordinator.listEntries` +
`listDisplayName(for:)`), the tap-to-open-detail behavior, and every underlying
operation (`disconnectController`, `splitJoyConPair`, `forgetController`) are
unchanged. No parser, encoder, or BLE code is touched.

## Scope

In scope:
- `WaveBird/UI/ContentView.swift` — `controllerList` container + a forget-confirm sheet host.
- `WaveBird/UI/ControllerRow.swift` — `LiveControllerRow` / `OfflineControllerRow` restyle + context menus.
- `WaveBird/UI/OptionHeldModifier.swift` — deleted (becomes unused).

Out of scope: the controller detail sheet/window, the menu-bar list
(`MenuBarContent`), profiles UI, any coordinator/data-layer logic.

## Design

### 1. List container

In `ContentView`, replace the `controllerList` `VStack(spacing: 8)` of cards
with a native grouped list containing a single section in the existing
`listEntries` order (connected-first, then offline by last-seen).

- Primary approach: `List { Section { ForEach(listEntries) … } }` with
  `.listStyle(.inset)`.
- Fallback if the rounded-group look doesn't match the screenshot:
  `Form { Section { … } }.formStyle(.grouped)` (this is what `ProfileDetailPane`
  already uses for the Settings-pane look — see `ProfileDetailPane.swift:73`).
- The choice is a visual-match detail settled during implementation; either way
  the row content and actions below are identical.

The surrounding chrome — `header`, `transportBanner`, `HIDAccessBanner`,
`emptyState`, and the footer `HStack` (Pair Joy-Cons / Set up Game Controller)
— and the window's `.frame(minWidth: 480, minHeight: 380)` are unchanged. The
list occupies the middle region and scrolls when tall.

### 2. Row restyle

`LiveControllerRow` and `OfflineControllerRow`:

- **Remove the status dot.** Delete the `Circle().fill(stateColor(...))`. Keep
  the text label from `stateLabel(_:)` ("Connected" / "Connecting…" / "Not
  Connected" / "Failed: …"). `stateColor(_:)` is deleted; `stateLabel(_:)` stays.
- **Keep the colored icon tile.** The rounded `gamecontroller.fill` square keeps
  its fill: `nintendoRed` / `gamecubeIndigo` when the VHID is active, `secondary`
  otherwise. This is the active-output signal (analogous to the branded icons in
  the screenshot), not a status dot.
- **Remove the inline bottom action.** Delete the
  `if record.connectionState == .ready { Divider(); Button("Disconnect…") }`
  block entirely, including the Option-held "Split Paired Controllers" swap.
- **Drop the per-card container.** Remove each row's own
  `.background(...)/.clipShape(...)`; the grouped list provides the container and
  separators.
- **Opportunistic macOS-15 nudge.** While rewriting, drop `.font(.default)` (use
  the natural default font). No behavior change; removes the one call the
  "lower deployment target to macOS 15" note flags. Not a goal of this work,
  just free while we're here.

### 3. Context menu

Attach `.contextMenu` to each row.

- **Live rows** (`LiveControllerRow`):
  - `Disconnect Controller` → `onDisconnect` (`disconnectController(record.id)`).
  - Merged Joy-Con pair row only: `Split Paired Controllers` → `onSplit`
    (`splitJoyConPair()` + dismiss the detail window, same as today's Option
    action). Shown whenever `onSplit != nil`; no Option key required.
  - Divider.
  - `Forget Controller` → routes through the forget confirmation (see §4).
- **Offline rows** (`OfflineControllerRow`):
  - `Forget Controller` only. Disconnect/Split don't apply to an offline row.

The context menu is the only place these actions live in the list now. Tapping
(left-click) a row still opens the detail window via `onSelect`.

### 4. Forget confirmation

`Forget Controller` reuses the existing `ForgetConfirmationSheet` (currently
presented only from `ControllerDetailSheet`) so list-forget gets the same
confirmation as detail-forget. Mirror `ControllerDetailSheet`'s exact pattern:

- Add a private `Identifiable` wrapper to `ContentView`:
  `struct ForgetConfirmation: Identifiable { let serial: String; let displayName: String; var id: String { serial } }`
  and `@State private var forgetConfirmation: ForgetConfirmation?`. (`.sheet(item:)`
  requires `Identifiable`, so a bare `String?` won't do.)
- Both row types gain an `onForget: () -> Void` closure; the row invokes it from
  its context menu, and `ContentView` sets `forgetConfirmation` to that entry's
  serial + display name.
- Present via `.sheet(item: $forgetConfirmation)` →
  `ForgetConfirmationSheet(displayName:onForget:onCancel:)`; on confirm, clear the
  item then `await coordinator.forgetController(serial:)` in a `Task { @MainActor }`.
- Serial/name source (both verified present): `record.serial` +
  `displayName` for `LiveControllerRow`; `paired.serial` + `paired.displayName`
  for `OfflineControllerRow`.
- Unlike the detail-sheet path, no `dismissWindow` is needed — the list has no
  window of its own to close.

### 5. Remove dead Option plumbing

With Split in the context menu (always shown for pair rows), the Option-held
swap is gone. Delete:

- `@State private var optionHeld` and the `.optionHeld($optionHeld)` modifier in
  `ContentView`.
- The `optionHeld` parameter and the button-swap branch in `LiveControllerRow`
  (`onSplit` stays — it's now the menu action).
- `WaveBird/UI/OptionHeldModifier.swift` — no remaining references
  (verified: only `ContentView` used it).

## What this is NOT

- Not a change to row ordering, selection, or detail-open behavior.
- Not touching the menu-bar list, which renders separately from `MenuBarContent`.
- Not adding an "Erase Controller Settings" op — the second menu item is
  `Forget Controller` mapping to the existing `forgetController(serial:)`.

## Testing & verification

Pure SwiftUI presentation over already-wired, already-hardware-validated
operations. No protocol/encoder/BLE change → **no hardware pass required**.

Verification:
1. `xcodebuild … build` succeeds.
2. Visual check against the reference screenshot: single grouped box, no status
   dots, no inline Disconnect button, chevron affordance intact.
3. Right-click menu shows the correct items per row type (live vs offline; pair
   vs solo), and each action performs the existing operation (disconnect, split,
   forget-with-confirmation).

No unit tests: there is no testable byte logic here (the testable core is
parsers/encoders/frame builders, none of which change).
