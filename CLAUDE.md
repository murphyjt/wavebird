# WaveBird

macOS app that bridges Nintendo Switch 2 controllers to a virtual HID gamepad. NS2 controllers don't pair via SMP and don't expose HID over GATT, so we connect via CoreBluetooth, parse Nintendo's proprietary 63-byte Report 0x05, and re-publish inputs through CoreHID's `HIDVirtualDevice`.

**How to read this file.** Two kinds of knowledge live here, with very different costs to get wrong:

1. **External facts** — NS2 wire-protocol behavior, macOS/SwiftUI/CoreHID bugs, SDL/GameController parsing quirks. Established by hardware experiments and OS spelunking, expensive to re-learn, and no refactor changes them. Sections: protocol gotchas, pairing, the MenuBarExtra warnings, `HID/Xbox.md`.
2. **Current design** — the coordinator split, the output catalog, persistence shapes, the dispatch-task pattern. These are *choices*, described so you can navigate, not so you preserve them. Improve them when you see a better shape; see "Working on this codebase" for how to do that safely. Nothing in the design sections is sacred except the facts in (1) and the invariants listed there.

## Scope

- **Shipped:** NSO/NS2 GameCube Controller, NS2 Pro Controller, and NS2 Joy-Con (L/R) over BLE, all with rumble. Joy-Cons work solo or as a merged L+R pair behind one virtual HID. LTK pairing (cmd 0x15) — paired controllers reconnect by pressing any button.
- **Deferred:** USB transport for incoming controllers. Protocol scaffolding (`USBMatcher`, `USBInitStep`, `parseUSBReport`) is intentionally kept in `Core/ControllerProfile.swift` so adding USB later is just writing the transport. A previous USB attempt hit IOKit issues with `com.apple.developer.hid.virtual.device` and was reverted — see git around `04b351d` / `37fc180` if reviving.

## Architecture (only the non-obvious bits — descriptive, not prescriptive)

- `@MainActor` types: `BridgeCoordinator`, `AppDelegate`, `LaunchAtLoginService`. Everything else is `nonisolated` by default — see Concurrency below. SwiftUI views inherit main-actor from `App`/`View`.
- `AppDelegate` (`WaveBird/AppDelegate.swift`) owns the coordinator and `LaunchAtLoginService` as plain `let` properties — instantiated once by `@NSApplicationDelegateAdaptor` before any scene renders, so scenes can share them via `appDelegate.coordinator` / `appDelegate.launch` instead of `@State`. It also drives startup (`IOHIDRequestAccess` + `coordinator.start()` + auto-scan from `applicationDidFinishLaunching`, so `.accessory`-mode launches with no window still work), re-evaluates the activation policy on window open/close/defaults change (any visible `canBecomeMain` window keeps the dock icon; re-evaluation on `willClose` defers one runloop tick to dodge the dock-ghost), registers sleep/wake observers (on `NSWorkspace.shared.notificationCenter`, not `NotificationCenter.default`), and kicks off `UpdateChecker.startBackgroundChecks()`.
- `BridgeCoordinator` is split across files in `WaveBird/Bridge/`. The type declaration, stored state, init/deinit, `start`, `toggleScan`, persistence, and small queries (`listEntries`, `listDisplayName`, `rumbleSettings`/`axisSettings`, `transport(for:)`, …) stay in `BridgeCoordinator.swift`. Behaviour lives in extension files: `+Pairing.swift` (LTK prompts + "Don't Ask Again" suppression), `+OutputMode.swift` (VHID creation, republish, set-report handler, per-mode secondary-input subscription), `+JoyConPair.swift` (pair form/split/promote/teardown + pair set-report handler), `+TransportEvents.swift` (`handle(_:kind:)`, per-device dispatch tasks, metadata, hexdumps), `+TestRumble.swift` (canned patterns), `+Power.swift` (sleep/wake disconnect + idle sweep — see Sleep, idle & updates below). Helper types pulled out alongside: `DeviceRecord.swift` (incl. `DeviceConnectionState`, `ListEntry`, `stderrLog`), `JoyConPair.swift`, `RawReport.swift`, `RumbleRefreshBox.swift`, `TestRumblePattern.swift`, `ActivityTracker.swift`. Because Swift's `private` doesn't cross files, most coordinator storage is plain `var` (not `private(set)`) — the UI must still treat it as read-only by convention.
- `listEntries` orders rows connected-first (`connectionRank`: ready/connected → connecting/discovered → disconnected/failed), then offline known controllers by last-seen; a live disconnected record never sits above a connected one. The main window and menu bar both render from `listEntries` + `listDisplayName(for:)`, which substitutes the merged pair name for the L-side stand-in row.
- Each `Transport` actor exposes one long-lived `AsyncStream<TransportEvent>` consumed once at startup. Reconnects do *not* require a new stream.
- Profiles (`WaveBird/Profiles/`) carry both transport-side data (matchers, parsers) and HID-side data (descriptor, report builder). One profile per controller spans both transports.
- Output modes live in a catalog (`HID/HIDOutputProfile.swift::HIDOutputCatalog`) rather than an enum. Adding a presentation is one entry + an impl file. Each entry produces a stateless `HIDOutputProfile` (identity: VID/PID/descriptor) and a per-connection `HIDOutputSession` (mutable handshake state, rumble parsing). Stateless outputs return `self`; the Switch Pro and Xbox presentations return fresh actors. Shipping modes: `switchPro`, `dualShock4`, `dualSense`, `xboxSeries`; `ns2Passthrough` and `switch2ProSDL` are `#if DEBUG` only.
- The Xbox mode is the deep one: a single virtual device serves GameController/Steam/web (Generic Desktop report `0x01`) *and* SDL HIDAPI/Dolphin (appended vendor GIP reports `0x20`/`0x07`) — full architecture, wire layouts, the SDL fragment-bit crash workaround, and the dual rumble paths are documented in `WaveBird/HID/Xbox.md`. Read that before touching `XboxSeriesOutputProfile.swift`. Per-serial GIP/Guide-routing toggles live in `XboxOutputSettings.swift` (same lock-guarded-snapshot shape as rumble/axis settings, sampled in the coordinator's dispatch task).
- `ControllerState` sticks are centered 12-bit (`SIMD2<Int16>`, working range −2047…2047, neutral 0) — the controller's native resolution end-to-end. Output encoders quantize down per presentation; the Switch Pro 12-bit path is bit-exact (re-add 2048). `WaveBirdTests` guards the rails/sign-flip class of bug.
- UI lives entirely in `WaveBird/UI/` (`ContentView`, `ControllerRow`, `ControllerDetailSheet`, `ControllerDetailWindow`, `MenuBarContent`, `SettingsView`, `RumbleSettingsCard`, `ProfilePickerSheet`, `JoyConPartnerSheet`, `SetupSheet`, `ForgetConfirmationSheet`, `UpdateAvailableView`, `OptionHeldModifier`). The pairing prompt sheet is in `WaveBird/Pairing/` next to the protocol code.

## Scenes

Three SwiftUI scenes in `WaveBirdApp.body`:

- `Window("WaveBird", id: "main")` — singleton main window (was `WindowGroup`; switched so there can only ever be one). Startup (HID permission + `coordinator.start()` + initial scan) lives in `AppDelegate`, **not** here, so launching without a window (login item, accessory mode) still connects controllers.
- `Window("Controller", id: "controller-detail")` with `.defaultLaunchBehavior(.suppressed)` — singleton detail window opened via `openWindow(id:)`. Selection is `coordinator.pendingDetailEntryID`; every caller sets it before opening and the window doesn't clear it on close, which sidesteps a race where SwiftUI evaluates the body against a stale nil and dismisses the window we just opened.
- `Settings { SettingsView(...) }` — toggles for *Launch at login* (via `SMAppService.mainApp`) and *Hide dock icon* (`NSApp.setActivationPolicy(.accessory/.regular)` at runtime; closes the main window first when going accessory to avoid the dock-ghost case).
- `MenuBarExtra("WaveBird", systemImage: "gamecontroller")` — always present (no toggle). **Do not** add `isInserted:` — binding the insertion state causes SwiftUI's main-menu graph to enter an infinite update loop on macOS 26.x. Conditional inclusion (`if showMenuBarItem { MenuBarExtra(...) }`) hits a Swift compiler crash ("failed to produce diagnostic for expression"). Always-present is the only stable shape. Same lesson for keyboard shortcuts inside the menu: don't add `.keyboardShortcut(",")` / `("q")` — they collide with the auto-generated Settings/Quit shortcuts and re-trigger the same main-menu update loop. Use `SettingsLink { Text("Settings…") }` (not `NSApp.sendAction(Selector(("showSettingsWindow:")))` — it doesn't route correctly from a status-item menu).

## Transport event lifecycle

```
.discovered → .connecting → .connected → .ready → (.reportReceived)* → .disconnected
```

- `.connected` = BLE link up; characteristics **not yet** discovered.
- `.ready` = characteristics discovered and `BLEMatcher.initCommands` fired. The coordinator builds the `VirtualHIDDevice` here, not on `.connected`.
- Any post-connect command pacing (init handshake, pairing dance) belongs between `.connected` and `.ready`.

## NS2 BLE protocol gotchas (learned the hard way)

- **Channel choice matters.** Write commands to the shared command char `649D4AC9-…-F005` (handle `0x0014`). Subscribe to the shared response char `C765A961-…-836A` (handle `0x001A`) — that's where the full ACK header + data payload lands. The per-controller "vibration + command" output (handle `0x0016`) and the per-controller response #2 char (handle `0x001E`) deliver only short acks, no data. We learned this the slow way.
- Output command char advertises both `.write` and `.writeWithoutResponse`. **Use `.withoutResponse`** — that's what works on hardware. `BLETransport.writeType(for:)` enforces this.
- BLE command frame is `[cmdID, 0x91, 0x01, subcmdID, 0x00, payloadLen, 0x00, 0x00, …payload]`. Response frame mirrors it as `[cmdID, 0x01, 0x01, subcmdID, 0x10, 0x78, 0x00, 0x00, …data]` — `0x78` is the success ack byte.
- **Match responses by cmd ID + subcmd.** A vibration cmd's ack can take >300 ms; without matching, a late ack can satisfy the next command's continuation. We use a 500 ms timeout per command. See `BLETransport.swift::responseMatches`.
- Defer the input-report notify subscription (handle `0x000A`) until after init completes; otherwise HID reports interleave with the command handshake.
- "Set Player 1 LED" is sent as `setLEDPattern` (cmd `0x09`, subcmd `0x07`, bitmask `0x01` + 7 zero bytes), *not* the dedicated `setPlayer1` (subcmd `0x01`). The single-byte-subcommand variant is documented as equivalent but isn't honored cold.
- The cmd `0x0A/0x08` "send vibration data" payload that SDL and BlueRetro both send during init has **unverified** purpose. SDL labels it `// Set rumble data?` (with a question mark). We mirror it because both refs do; don't claim it "enables" anything.
- Controller produces input reports at ~1000 Hz natively. BLE delivers ~70 Hz (link-side cap; see memory). Feature flags only gate which fields of report 0x05 are populated, not the production rate.
- Streaming rumble is written to the vibration output char (handle `0x0012`; per-controller UUIDs in `Core/NS2BLE.swift`). The packet is what BR/SDL call "Output Report 0x03" for GC (single on/off motor), "0x02" for Pro (LRA HF+LF), "0x01" for JoyCons — *not* a HID report-ID prefix; the wire byte 0 is 0x00 and byte 1 carries `enable | ops_cnt | tid`. GC, Pro, and JoyCon paths all ship; the merged pair splits one `RumbleCommand` into per-side single-motor frames.
- **Subscribing to a secondary input characteristic can suppress the primary.** Subscribing to Pro's per-controller input handle `0x000E` (Report 0x09) stops Report 0x05 — which the state-translation path parses — from arriving. So secondaries are opt-in per output mode, not auto-subscribed: `BLEMatcher.secondaryInputs` is the *catalog* of available channels, the transport subscribes only the primary (`0x000A`) at init, and `BridgeCoordinator.applySecondaryInputs` calls `Transport.setSecondaryInputs(_:for:)` with the resolved mode's `HIDOutputProfile.requiredSecondaryReportIDs` when a mode activates. Every shipping presentation requires none.
- Full command table: ndeadly's `switch2_controller_research/commands.md` (cloned at `/Users/joshua/Developer/switch2_controller_research/`).

## Pairing (LTK exchange, cmd 0x15)

- Nintendo runs its own pseudo-OOB key exchange over the same command channel as init — no SMP. Four-step exchange in `Pairing/NS2Pairing.swift`, frame builders in `Pairing/NS2PairingFrames.swift`. On wire, all multi-byte fields (addresses, keys, challenges, AES blocks) are byte-reversed; reversal happens inside the frame builders, callers pass natural (MSB-first) order.
- Host BT address comes from `IOBluetoothHostController.default()` (`Pairing/HostAdapter.swift`). CoreBluetooth doesn't expose it; IOBluetooth is the only public surface that does. Already covered by `com.apple.security.device.bluetooth` in `WaveBird.entitlements` — no extra entitlement.
- Controller stores up to two paired hosts in flash `0x1FA000`. We read it during init (`NS2Commands.pairingInfoRead`) and cross it with our local record to decide between two prompt intents (`PairingPrompt.Intent`): `.pair` (neither side knows) and `.repair` (we have a record, controller forgot us). Two cases raise no prompt: controller knows us but we don't → silently adopt (upgrade the local record to `isPaired`, no wire exchange); both sides agree → nothing. A failed flash read falls back to local-only logic.
- Pairing overwrites the controller's Switch 2 console slot — that's a user-facing warning in the prompt copy, not something we can avoid.
- The prompt's bottom-left **"Don't Ask Again"** button (`declinePairingPermanently`) persists a per-serial suppression so the prompt never reappears across launches; "Not Now" only suppresses for the session. Forgetting the controller clears the suppression.
- Local "forget" only clears WaveBird's record; the on-device LTK persists until the controller is re-paired with something else. We don't currently send `0x15/0x03` to clear it on the device.
- Persisted as JSON in `UserDefaults` under `WaveBird.knownControllers` (`[serial: KnownController]`). Each record carries `displayName`, `productID`, `lastSeenAt`, last-seen `peripheralUUID`, `isPaired`, an optional `preferredOutputModeID` (per-serial "Use profile", applied at the next `.ready`), and an optional `suppressPairingPrompt`. New fields are `Bool?`/`String?` so older blobs still decode — the whole dict decodes in one shot, and a missing non-optional key would wipe every record.

## Rumble

- `RumbleSettings` (one per controller serial, persisted in `UserDefaults` keyed `WaveBird.rumble.<serial>`; the merged Joy-Con pair uses `"Lserial+Rserial"`) drives per-band frequency/amplitude tuning. `productID` is retained on the instance only for the `isGameCube` UI flag, not as the persistence key. The Observation registrar is thread-safe; the inner `OSAllocatedUnfairLock` guards the `Snapshot` struct so the BLE write queue can sample without touching `@MainActor` state.
- Profiles take a `Snapshot` parameter on `encodeRumble`. GC ignores everything except `intensity` (single on/off motor — `RumbleSettings.isGameCube` is the UI's flag for hiding the tuning controls). Pro reads all of it.
- `intensity == 0` short-circuits non-stop sends in both profiles (saves BLE bandwidth); stop frames still go through so an active rumble can be quieted.
- The set-report handler arms a 1 s watchdog after each rumble command. If no new rumble arrives within that window the coordinator force-sends a stop — keeps a hung/foreground-lost game from leaving a paired controller buzzing. Every supported host's refresh cadence (DS4 ~33 ms, Xbox 80 ms, Pro 15 ms) is well inside that deadline.
- Test rumble runs on `Task.detached` so its heartbeat loop never shares an executor with the UI. The gameplay rumble path is already off-main via the HID set-report handler.
- `republishVirtualHID` broadcasts an explicit stop before tearing down the VHID so repeated mode toggles can't leave the motor on.

## Input config

- `AxisSettings` (one per controller serial, keyed like rumble under `WaveBird.axis.<serial>`) holds per-stick Y-axis inversion. Same thread-safe `OSAllocatedUnfairLock<Snapshot>` shape so the off-main dispatch task samples it per report. Applied via `ControllerState.invertingY(left:right:)` right before `buildReport` (solo) / after the pair merge — presentation-agnostic, so passthrough-style raw-forwarding paths (which bypass `buildReport`) aren't affected.
- All per-controller settings (rumble, axis, preferred output mode) key by NS2 serial; the merged Joy-Con pair keys by `"Lserial+Rserial"` (L first). No per-PID/device-wide fallback persists.
- `ControllerDetailSheet` is three tabs: **General** (Use profile + Sticks), **Haptics** (rumble card + test row), **About** (per-side serial/firmware; a pair shows both sides).

## Sleep, idle & updates

- On `NSWorkspace.willSleepNotification` the coordinator clean-disconnects every controller and stops scanning (`prepareForSleep`); `didWake` restarts scanning so paired controllers reconnect on the next button press. Best-effort — the OS tears BLE down regardless. Closed-lid clamshell with an external display keeps the Mac awake, so `willSleep` never fires there and controllers stay connected.
- Idle timeout: a once-a-minute sweep (`runIdleSweep`, started from `start()`) disconnects any `.ready` controller with no input change for `WaveBird.idleDisconnectMinutes` (default 10, `0` = off). Timestamps come from `ActivityTracker` — a `Sendable` unfair-lock dictionary written by the off-main dispatch tasks (captured by value, matching the settings-snapshot pattern) and read on main; `ContinuousClock` so it's immune to sleep/wall-clock skew.
- `UpdateChecker` (`WaveBird/UpdateChecker.swift`) is a manual + daily-background check against GitHub `releases/latest` — deliberately not Sparkle (no appcast/signing keys; see the shelved-Sparkle memory if silent auto-install is ever wanted). Background checks are `#if !DEBUG` (debug builds are versioned `0.0.0-dev`, which every release outranks). "Skip This Version" persists to `WaveBird.skippedUpdateVersion` and only silences background checks; a manual check always shows what's available. The sheet is a plain `NSWindow` held in a static (not a SwiftUI scene).

## Concurrency

- Swift 6.2, strict concurrency, default actor isolation is `nonisolated` (`SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`). The `NonisolatedNonsendingByDefault` upcoming feature is on.
- New types default to `nonisolated`. Don't add `@MainActor` unless the type genuinely needs main-actor isolation (UI bindings, observation).
- `@preconcurrency import CoreBluetooth` in any file typing CB types. Same for `IOBluetooth` (used only in `HostAdapter`).
- The per-device input pipeline runs **off** the main actor. `handle(.reportReceived)` only routes on main — it yields the raw report into a per-device `AsyncStream<RawReport>` (`bufferingNewest(1)`); a `Task.detached(.userInitiated)` does parse → `buildReport` → `vhid.dispatch`, capturing `vhid`/`session`/`profile`/`calibration`/axis settings as Sendable locals (never `self`). Because those are captured by value, `republishVirtualHID` must restart the dispatch task after swapping the VHID. **Exception:** a Joy-Con pair's two sides share one VHID, so `startPairDispatch` stays `@MainActor` — main serializes the per-side state merge and the concurrent dispatch to the shared device. Solo devices each own a distinct VHID, so their detached tasks share no mutable state.
- `stderrLog` is async and `#if DEBUG`-only (writes on a detached background task), so set-report/diagnostic logging never blocks the CoreHID executor — and vanishes from release builds.

## Build

```sh
xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build
```

`PBXFileSystemSynchronizedRootGroup` means new `.swift` files under `WaveBird/` auto-include — no `project.pbxproj` edits per file.

Unit tests (Swift Testing, in `WaveBirdTests/`):

```sh
xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests
# single suite: -only-testing:WaveBirdTests/StickMappingTests
```

Coverage is deliberately narrow: `StickMappingTests` (12-bit stick pipeline rails/sign-flip regressions) and `NS2PairingVectorTests` (LTK frames against ndeadly's published example vectors — if these fail, the byte-reversal convention has drifted and controllers will reject pairing). `WaveBirdUITests` is untouched template scaffolding — skip it.

The build verifies *code* correctness, not *gamepad* correctness. Anything touching parsing, HID output, or BLE commands needs hardware validation; say so explicitly when you can't test it yourself.

`Tools/` holds standalone diagnostics, not app targets: `Dump.swift` (controller flash dumper; the `.bin` files alongside are captured dumps), `GameControllerProbe.swift` (prints what `GCController` exposes for a connected pad — used to verify the Xbox spoof against real hardware), `RumbleTest.swift`, `trace_transport.swift`, `sw2_sdl_probe.c`. Compile ad hoc with `swiftc`.

## Release

Tag-driven (`v*`) via `.github/workflows/release.yml`: builds Release with hardened runtime, **re-signs explicitly to strip Xcode-injected `get-task-allow`**, notarizes the `.app` and DMG, attests SLSA provenance, publishes a GitHub Release. Runner pinned to `macos-26` (matches the macOS 26 SDK). Don't bump the runner without rechecking SDK availability. Release notes are generated by git-cliff (`cliff.toml`) over the previous-release…tag range; `UpdateChecker` renders the release body in-app (it truncates at the first `<details>` block — keep provenance/changelog-link boilerplate below one).

## External references

- ndeadly protocol docs, cloned: `/Users/joshua/Developer/switch2_controller_research/` (`commands.md`, `bluetooth_interface.md`, `hid_reports.md`). Authoritative for what's documented; many fields are still labeled "Unknown" or "Format not yet fully understood."
- SDL HIDAPI Switch2 driver, cloned: `/Users/joshua/Developer/SDL/src/joystick/hidapi/SDL_hidapi_switch2.c`. The flash addresses for serial (`0x13000`) and trigger calibration (`0x13140`) come from here. zlib license; **credit `libsdl-org/SDL` in source comments and in README Credits when porting** (already done for the trigger-zero code).
- [darthcloud/BlueRetro](https://github.com/darthcloud/BlueRetro) — Apache 2.0. GC support in `main/adapter/wireless/sw2.c`. Re-implementation in Swift creates no obligation; near-verbatim ports of a BR file should carry a header crediting darthcloud.

## Working on this codebase

### The economics: hardware validation is the bottleneck

The compiler and the small unit suite are the only automated verification. Everything that matters — pairing, reconnect, rumble feel, whether Dolphin/Steam/a browser sees the pad — needs a human with physical controllers. Code is cheap here; verification is not. Structure work around that:

- Split behavior-preserving refactors from behavior changes into separate commits, and say explicitly which commits need a hardware pass. A refactor that leaves parsing/encoding byte-identical needs none; one that "improves" a frame does.
- Before refactoring a parser/encoder, pin it with golden-byte tests (the `NS2PairingVectorTests` pattern): representative inputs → exact expected bytes, refactor, prove identical. Bytes captured from real controllers (hexdump logs, `Tools/` flash dumps) beat synthetic vectors.
- Never invent protocol bytes. If neither ndeadly, SDL, BlueRetro, nor a captured dump documents a field, it is *unknown* — say so in the code and leave it alone. Plausible-looking filler that happens to work on one controller is how protocol code rots.

### Things that look wrong but are load-bearing

Several oddities are the survivors of failed alternatives: bit-7 masking in Xbox report `0x01`, `setLEDPattern` instead of `setPlayer1`, `.withoutResponse` writes, the always-present `MenuBarExtra`, deferred input subscription, `pendingDetailEntryID` never clearing on close. Before "fixing" anything that looks like a bug, dead code, or an inconsistency, check this file, the memory index, and `git log -S`. If you change an empirically-derived behavior anyway, flag it loudly as needing hardware retest — don't fold it silently into a cleanup.

### Architecture: what's fluid

The current shape has known debts. Treat them as invitations, not fixtures:

- `BridgeCoordinator` is a god object; the extension-file split is a coping mechanism, and its "read-only by convention" storage is a privacy hole Swift can't express across files. Extracting cohesive pieces — e.g. a per-device connection/session type owning its VHID, dispatch task, and state; a known-controllers store separate from live-device orchestration — would be a genuine improvement.
- The Joy-Con pair is a special case threaded through the coordinator (`+JoyConPair`, the main-actor pair-dispatch exception). A design where "input source" (solo device *or* merged pair) is first-class would erase most of that.
- Persistence is hand-rolled JSON-in-UserDefaults where one non-optional new field wipes every record. A versioned decode, or per-record decode-with-recovery, is a straightforward upgrade.
- `ControllerProfile` conflates transport parsing with HID-side data; the deferred-USB scaffolding lives there on purpose, but the boundary is renegotiable when USB actually lands.

If you see a better overall shape, propose it. Constraints on any rewrite: preserve wire behavior and persisted-data compatibility, and land it as its own reviewable change — never bundled into feature work, never more than one architectural seam at a time.

### What's actually fixed

- The protocol facts and macOS workarounds in this file — hardware/OS constraints, not design.
- User-visible invariants: paired controllers reconnect on a button press; per-serial settings survive updates; each shipping output mode keeps working in its known consumers (GameController apps, Steam, browsers, SDL/Dolphin).
- Persisted UserDefaults keys and blob formats are user data. Migrate; never rename-and-lose.
- The complexity budget: this is a small single-purpose utility with exactly two transports ever (BLE now, USB someday) and one developer. Design for that N, not for generality.

### Concurrency habits (Swift 6.2 strict, `nonisolated` default)

- Don't reach for `@MainActor` to silence a diagnostic; make the type Sendable or move the work. Main actor is for UI and observation only.
- The hot path is per-report at ~70 Hz per controller (parse → build → dispatch). Keep it allocation-light and lock-brief — but 70 Hz is slow by CPU standards, so don't contort the design for micro-throughput either.
- The capture-by-value discipline in dispatch tasks (Sendable locals, never `self`) is what makes the off-main pipeline safe, and its cost is the restart-after-swap rule. If you replace the pattern, replace it wholesale (e.g. a per-device actor owning its pipeline); a half-migrated hybrid is worse than either endpoint.
- Cross-thread settings reads use the `OSAllocatedUnfairLock<Snapshot>` idiom (rumble, axis, Xbox, ActivityTracker). Reuse it or replace it everywhere — don't introduce a third synchronization style.

### Testing: where it pays and where it doesn't

- The testable core is pure functions over bytes: report parsers, stick math, report builders, pairing/rumble frame builders. Extend the vector suites whenever you touch one.
- Don't mock CoreBluetooth/CoreHID or protocol-ize OS types for testability. The integration risk lives in the OS and the hardware, where mocks can't reach, and the abstraction tax lands on every reader. This is the "no abstractions for unobserved problems" rule applied to tests.

### Sources of truth

- Every protocol claim in code or commits cites its source: an ndeadly doc section, an SDL function, a BlueRetro file, or "verified on hardware <date>". Mirroring unverified behavior is fine — SDL and BR do it — but label it *mirrored*, not *understood* (the cmd `0x0A/0x08` note above is the model).
- The references disagree in places (SDL and BR pack rumble bytes differently; see memory). When they conflict, don't silently pick one — note the conflict and prefer whichever variant was validated on hardware.

## Conventions

- Small, mechanical changes. No error handling, fallbacks, or abstractions for problems we haven't observed.
- Comments only when the *why* is non-obvious. Don't narrate what the code does.
- Commit messages: short title (≤72 chars), 2–4 line body, no narrative.
- New code defaults to `nonisolated`.
- BLE writes prefer `.withoutResponse`.
