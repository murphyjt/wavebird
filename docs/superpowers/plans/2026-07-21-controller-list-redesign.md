# Controller List Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the main window's controller list read like macOS System Settings → Game Controllers — a grouped/inset list with no status dots and no inline buttons, with row actions on a right-click context menu.

**Architecture:** Pure SwiftUI presentation swap in two files (`ContentView.swift`, `ControllerRow.swift`) plus deleting one now-unused modifier file. The data source (`coordinator.listEntries` + `listDisplayName(for:)`), tap-to-open-detail, and every underlying operation (`disconnectController`, `splitJoyConPair`, `forgetController`) are unchanged. No parser/encoder/BLE code is touched.

**Tech Stack:** SwiftUI (macOS), Swift 6.2 strict concurrency.

## Global Constraints

- **No automated tests for this work.** The testable core is byte logic (parsers/encoders/frame builders); none of it changes. Verification per task is: `xcodebuild … build` succeeds + a manual visual/functional check. Do not add unit tests.
- **Build command:** `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build` → expect `** BUILD SUCCEEDED **`.
- **Every commit must compile and keep disconnect available** (from the list or, transiently, the detail sheet). Tasks are ordered to preserve this.
- **Keep the colored icon tile** (`nintendoRed` / `gamecubeIndigo` when VHID active, `secondary` otherwise). Only the status *dots* are removed.
- **Commit style:** short title (≤72 chars), 2–4 line body, no narrative. End with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **`nonisolated` default** — do not add `@MainActor`; SwiftUI views inherit it.

---

### Task 1: Grouped list container + row destyle

Convert the list to a native grouped/inset `List`, remove the status dots, the per-card background, and both `.font(.default)` calls. The inline Disconnect/Split button and the `optionHeld` plumbing stay untouched this task, so disconnect keeps working and nothing about the actions changes yet — this is a visual-only step.

**Files:**
- Modify: `WaveBird/UI/ContentView.swift` (`controllerList`, ~213-244)
- Modify: `WaveBird/UI/ControllerRow.swift` (`LiveControllerRow` body ~32-88; `OfflineControllerRow` body ~114-147)

**Interfaces:**
- Consumes: `coordinator.listEntries`, `coordinator.listDisplayName(for:)`, `coordinator.joyConPair`, `coordinator.joyConPairVHIDActive` (all unchanged).
- Produces: no signature changes. `LiveControllerRow` / `OfflineControllerRow` keep their current initializers.

- [ ] **Step 1: Wrap the list in `List`/`Section` in `ContentView.controllerList`**

Replace the whole `controllerList` computed property. Only the outer container changes (`VStack(spacing: 8)` → `List { Section { … } }.listStyle(.inset)`); the `ForEach` body is copied verbatim.

```swift
    private var controllerList: some View {
        List {
            Section {
                ForEach(coordinator.listEntries) { entry in
                    if let record = entry.live {
                        let pair = coordinator.joyConPair
                        let isPairLeft = pair?.leftID == record.id
                        LiveControllerRow(
                            record: record,
                            paired: entry.paired,
                            isVHIDActive: entry.vhidActive,
                            displayNameOverride: isPairLeft ? coordinator.listDisplayName(for: entry) : nil,
                            vhidActiveOverride: isPairLeft ? coordinator.joyConPairVHIDActive : nil,
                            optionHeld: optionHeld,
                            onSplit: isPairLeft ? {
                                Task { await coordinator.splitJoyConPair() }
                                dismissWindow(id: "controller-detail")
                            } : nil,
                            onSelect: { openDetail(for: entry.id) },
                            onDisconnect: { Task { await coordinator.disconnectController(record.id) } }
                        )
                    } else if let paired = entry.paired {
                        OfflineControllerRow(paired: paired) {
                            openDetail(for: entry.id)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
```

- [ ] **Step 2: Destyle `LiveControllerRow` — drop the dot, the name font, the card**

In `WaveBird/UI/ControllerRow.swift`, edit `LiveControllerRow.body`. Remove `.font(.default)` from the name `Text`, delete the status-dot `Circle`, and remove the outer `.background(...).clipShape(...)`. Keep everything else (icon tile, inline `.ready` button block, `stateLabel`).

Change the name `Text`:
```swift
                            Text(displayName)
                                .foregroundStyle(.primary)
```

Change the status line (delete the `Circle`, keep the label):
```swift
                        HStack(spacing: 6) {
                            Text(stateLabel(record.connectionState))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
```

Remove the two trailing modifiers on the outer `VStack(spacing: 0)` — delete these lines:
```swift
        .background(Color.secondary.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
```

- [ ] **Step 3: Delete the now-unused `stateColor` helper in `LiveControllerRow`**

The dot was its only caller. Delete:
```swift
    private func stateColor(_ s: DeviceConnectionState) -> Color {
        switch s {
        case .connected, .ready: .green
        case .connecting, .discovered: .orange
        case .disconnected: .red
        case .failed: .red
        }
    }
```

- [ ] **Step 4: Destyle `OfflineControllerRow` — drop the dot, the name font, the card**

Edit `OfflineControllerRow.body`. Remove `.font(.default)`, delete the `Circle`, and remove `.background(...).clipShape(...)` from inside the button (keep `.padding(10)` and `.contentShape(Rectangle())`).

Name `Text`:
```swift
                    Text(paired.displayName)
                        .foregroundStyle(.primary)
```

Status line (delete the `Circle`, keep the label):
```swift
                    HStack(spacing: 6) {
                        Text("Not Connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
```

Delete these two lines from the `HStack`'s modifier chain (leave `.padding(10)` above them and `.contentShape(Rectangle())` below):
```swift
            .background(Color.secondary.opacity(0.065))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`. If it fails on an unused `stateColor` or a leftover `.font(.default)`, re-check Steps 2–4.

- [ ] **Step 6: Manual visual check**

Launch the app with at least one controller connected (and ideally one known-but-offline).
Expected:
- The list renders as one grouped, inset, rounded box with hairline separators between rows — not the old free-floating cards.
- No colored status dots anywhere; the "Connected" / "Not Connected" text label remains.
- The colored icon tile still reflects active state.
- Clicking a row still opens the detail window.
- The inline "Disconnect Controller" button (and Option → "Split Paired Controllers" on a pair) still appears and works — unchanged this task.
- If the grouped box doesn't match System Settings (e.g. row insets look off, or the list background clashes with the window), adjust: try `.listStyle(.inset)` row insets via `.listRowInsets(EdgeInsets())`, or fall back to `Form { Section { … } }.formStyle(.grouped)` (the shape `ProfileDetailPane.swift:73` uses). This is the one visual-iteration point.

- [ ] **Step 7: Commit**

```bash
git add WaveBird/UI/ContentView.swift WaveBird/UI/ControllerRow.swift
git commit -m "ui: grouped inset controller list, drop status dots" -m "Wrap the list in a native grouped List/Section; remove the red/green
status dots, the per-card background, and both .font(.default) calls." -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Right-click context menu + remove inline actions

Move the row actions onto a `.contextMenu`, add the Forget-with-confirmation flow (reusing `ForgetConfirmationSheet`), and delete the inline button block and the `optionHeld` plumbing. This task changes row initializers and their `ContentView` call sites together so the build stays green.

**Files:**
- Modify: `WaveBird/UI/ControllerRow.swift` (`LiveControllerRow`, `OfflineControllerRow`)
- Modify: `WaveBird/UI/ContentView.swift` (`controllerList` call sites, forget-sheet host, remove `optionHeld` state + modifier)
- Delete: `WaveBird/UI/OptionHeldModifier.swift`

**Interfaces:**
- Consumes: `ForgetConfirmationSheet(displayName: String, onForget: () -> Void, onCancel: () -> Void)`; `coordinator.forgetController(serial: String) async`; `record.serial`, `paired.serial`, `paired.displayName`; `coordinator.listDisplayName(for:)`.
- Produces: `LiveControllerRow` gains `onForget: () -> Void`, loses `optionHeld: Bool`. `OfflineControllerRow` gains `onForget: () -> Void`. `ContentView` gains a private `ForgetConfirmation: Identifiable` + `@State forgetConfirmation`.

- [ ] **Step 1: Add the context menu + `onForget` to `LiveControllerRow`, remove the inline block and `optionHeld`**

In `ControllerRow.swift`, update `LiveControllerRow`.

Replace the property `var optionHeld: Bool = false` with:
```swift
    let onForget: () -> Void
```
(Delete the `optionHeld` stored property and its doc comment; keep `onSplit`, `onSelect`, `onDisconnect`.)

Delete the entire inline action block — from `if record.connectionState == .ready {` through its closing `}` (the `Divider()` + `HStack { … Disconnect/Split … }.padding(10)` section), leaving just the `Button(action: onSelect) { … }.buttonStyle(.plain)` as the row body.

Attach a context menu to the row. The row body is currently the `VStack(spacing: 0) { Button … }`; since the inline block is gone, simplify to the button plus a `.contextMenu`:
```swift
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(vhidActive ? record.firmware?.controllerType == 0x03 ? .gamecubeIndigo : .nintendoRed : Color.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: 6) {
                        Text(stateLabel(record.connectionState))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if record.connectionState == .ready {
                Button("Disconnect Controller", action: onDisconnect)
                if let onSplit {
                    Button("Split Paired Controllers", action: onSplit)
                }
                Divider()
            }
            Button("Forget Controller", role: .destructive, action: onForget)
        }
    }
```

- [ ] **Step 2: Add the context menu + `onForget` to `OfflineControllerRow`**

`OfflineControllerRow` currently declares `let paired` and `let onSelect`. Add a stored property after `let onSelect: () -> Void`:
```swift
    let onForget: () -> Void
```
Then attach a `.contextMenu` to the existing `Button`, which currently ends with `.buttonStyle(.plain)` — replace that trailing modifier line with:
```swift
        .buttonStyle(.plain)
        .contextMenu {
            Button("Forget Controller", role: .destructive, action: onForget)
        }
```

- [ ] **Step 3: Add the forget-confirmation host to `ContentView`**

In `ContentView.swift`, add the state and Identifiable wrapper near the other `@State` (after `optionHeld` — which is removed in Step 5, so place it near `showSetupSheet`):
```swift
    @State private var forgetConfirmation: ForgetConfirmation?

    private struct ForgetConfirmation: Identifiable {
        let serial: String
        let displayName: String
        var id: String { serial }
    }
```

Add the sheet host. Attach it alongside the other `.sheet(...)` modifiers on the `body`'s root `VStack` (e.g. right after the `SetupSheet` sheet):
```swift
        .sheet(item: $forgetConfirmation) { confirm in
            ForgetConfirmationSheet(
                displayName: confirm.displayName,
                onForget: {
                    let serial = confirm.serial
                    forgetConfirmation = nil
                    Task { @MainActor in
                        await coordinator.forgetController(serial: serial)
                    }
                },
                onCancel: { forgetConfirmation = nil }
            )
        }
```

- [ ] **Step 4: Wire `onForget` into the row call sites in `controllerList`**

Update the two row constructions from Task 1. For `LiveControllerRow`, remove the `optionHeld: optionHeld,` argument and add `onForget`:
```swift
                        LiveControllerRow(
                            record: record,
                            paired: entry.paired,
                            isVHIDActive: entry.vhidActive,
                            displayNameOverride: isPairLeft ? coordinator.listDisplayName(for: entry) : nil,
                            vhidActiveOverride: isPairLeft ? coordinator.joyConPairVHIDActive : nil,
                            onSplit: isPairLeft ? {
                                Task { await coordinator.splitJoyConPair() }
                                dismissWindow(id: "controller-detail")
                            } : nil,
                            onSelect: { openDetail(for: entry.id) },
                            onDisconnect: { Task { await coordinator.disconnectController(record.id) } },
                            onForget: {
                                forgetConfirmation = ForgetConfirmation(
                                    serial: record.serial,
                                    displayName: coordinator.listDisplayName(for: entry)
                                )
                            }
                        )
```
For `OfflineControllerRow`, switch from trailing-closure `onSelect` to explicit args plus `onForget`:
```swift
                    } else if let paired = entry.paired {
                        OfflineControllerRow(
                            paired: paired,
                            onSelect: { openDetail(for: entry.id) },
                            onForget: {
                                forgetConfirmation = ForgetConfirmation(
                                    serial: paired.serial,
                                    displayName: paired.displayName
                                )
                            }
                        )
                    }
```

- [ ] **Step 5: Remove the `optionHeld` plumbing and delete `OptionHeldModifier.swift`**

In `ContentView.swift`:
- Delete the state and its comment:
```swift
    // True only while the Option key is physically held. Pair rows read this
    // to swap Disconnect → Split.
    @State private var optionHeld = false
```
- Delete the modifier on `body` (the last line before the closing brace of `body`):
```swift
        .optionHeld($optionHeld)
```

Delete the file:
```bash
git rm WaveBird/UI/OptionHeldModifier.swift
```

- [ ] **Step 6: Build**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`. Common failures: a leftover `optionHeld:` argument, a missing `onForget:` argument at a call site, or a lingering reference to `OptionHeldModifier` / `.optionHeld(`.

- [ ] **Step 7: Manual functional check**

Launch with a connected controller and (ideally) a known-offline one, plus a merged Joy-Con pair if available.
Expected:
- No inline buttons remain in any row.
- Right-click a connected solo controller → `Disconnect Controller`, divider, `Forget Controller`. Disconnect drops the link; the controller reconnects on a button press.
- Right-click a merged Joy-Con pair → `Disconnect Controller`, `Split Paired Controllers`, divider, `Forget Controller`. Split tears down the merged VHID (same as the old Option action).
- Right-click an offline controller → `Forget Controller` only.
- `Forget Controller` opens the confirmation sheet naming the controller; confirming forgets it (row leaves the list / re-prompts on next connect); cancel leaves it untouched.
- Left-click still opens the detail window.
- Holding Option no longer changes anything in the list (plumbing gone).

Note (known limitation, acceptable): forgetting from a *pair* row forgets the L-side serial (`record.serial`); full pair management remains in the detail sheet. Do not expand scope here.

- [ ] **Step 8: Commit**

```bash
git add WaveBird/UI/ContentView.swift WaveBird/UI/ControllerRow.swift
git commit -m "ui: row actions in right-click menu, drop inline buttons" -m "Move Disconnect/Split/Forget to a .contextMenu; Forget reuses
ForgetConfirmationSheet. Remove the inline button block and the
now-dead optionHeld plumbing; delete OptionHeldModifier." -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Out of scope (do not do here)

- Lowering `MACOSX_DEPLOYMENT_TARGET` to 15.0 — a **separate follow-up** after this branch lands (its own build pass + commit). This plan only removes the sole blocker (`.font(.default)`); see the design spec's "Follow-up" section.
- The menu-bar list (`MenuBarContent`), the detail sheet/window, and all coordinator/data-layer logic are untouched.
