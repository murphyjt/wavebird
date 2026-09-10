# NS2 Relay Output Mode (WaveBird side) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a DEBUG-only `ns2Relay` output mode that publishes a solo NS2 controller under its real VID/PID and tunnels SDL's Switch 2 driver commands over HID reports `0x80`/`0x81`, replacing the `ns2Passthrough` and `switch2ProSDL` precursors.

**Architecture:** A stateless `NS2RelayOutput` (profile + session) does all byte transforms as pure functions (report `0x05` framing, rumble ID rewrite, tunnel-frame trimming). A per-connection `CommandTunnel` actor serialises every post-`.ready` `sendAwaitingResponse` so CoreHID's concurrent set-reports and a late pairing exchange can never overlap on `BLETransport`'s no-overlap precondition. The coordinator's set-report handler gains one branch (tunnel) ahead of the rumble branches and a 1 s stop watchdog on the raw-rumble path.

**Tech Stack:** Swift 6.2 (strict concurrency, `nonisolated` default), CoreHID `HIDVirtualDevice`, CoreBluetooth via `BLETransport`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-10-ns2-relay-design.md` — read it first. This plan implements its "WaveBird design", "The HID contract", "Catalog and cleanup" and "Tests" sections. The SDL half is a separate plan: `docs/superpowers/plans/2026-09-10-sdl-virtual-transport.md`.

## Global Constraints

- The `ns2Relay` catalog entry is `#if DEBUG` only. Display name: `"NS2 Relay (SDL)"`. It never appears in `HIDOutputCatalog.allowListIDs`.
- Solo controllers only (Pro `0x2069`, GC `0x2073`, Joy-Con L `0x2067`, Joy-Con R `0x2066`). `JoyConPairProfile` is untouched; the merged pair never relays.
- Never subscribe Pro's secondary handle `0x000E` (Report `0x09`): `requiredSecondaryReportIDs` stays the protocol default (empty).
- Tunnel frame byte 2 is rewritten `0x00 → 0x01` on the way to the controller. Responses are never modified.
- Command ID `0x15` (LTK pairing) is dropped with no response.
- One command in flight per device; bridge-side tunnel timeout is `.seconds(1)`.
- Rumble output reports `0x01` (Joy-Con) / `0x02` (Pro) / `0x03` (GC) are relayed verbatim with byte 0 rewritten to `0x00`, trimmed to 42 bytes (what `encodeRumble` produces today for all three profiles).
- CoreHID delivers set-report `data` **with the report ID at index 0** (verified by the shipping DualSense `parseRumble` reading `data[3]`/`data[4]` and Xbox reading `data[2...5]` — both real-layout offsets that include the ID byte). Every offset in this plan assumes that.
- Persisted `UserDefaults` keys and blob formats are user data: no migration is added or needed; stale `preferredProfileID` values for the removed modes already fall back through `resolveMappingProfile`.
- Wire behaviour for every shipping mode is unchanged. The only intentional behaviour change on a non-relay path is that the LTK pairing exchange now routes through `CommandTunnel` (byte-identical frames; serialisation only).
- Build: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
- Test: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
- SourceKit may emit cross-file "Cannot find type … in scope" / "No such module 'Testing'" diagnostics — the `xcodebuild` result is authoritative.
- Commit messages: short title (≤72 chars), 2–4 line body, no narrative. End each with the attribution trailer given in the session's system reminder.
- Hardware validation is required for every task marked **[hardware]** before this is considered done; the plan tells you what to verify. Say so in the commit body when you couldn't run it.

## Design notes that refine the spec

Two details the spec leaves implicit; both are decided here so implementers don't re-derive them:

1. **GC and Joy-Con relay descriptors need a Generic Desktop / Game Pad outer collection.** SDL's `HIDAPI_IGNORE_DEVICE` (with the default `SDL_HINT_HIDAPI_ENUMERATE_ONLY_CONTROLLERS`) drops any device whose top-level usage isn't Generic Desktop Joystick/Game Pad/Multi-axis. The old `ns2VendorDescriptor` had a bare vendor-page collection and would be invisible to SDL. The relay descriptor for GC and Joy-Con is therefore `Game Pad` collection → vendor input `0x05` (63 B) → vendor output rumble ID (63 B) → tunnel block. Pro keeps its real USB descriptor plus the tunnel block.
2. **`CommandTunnel` lives for the connection, not the VHID.** The spec says "created per relay device, torn down with the VHID". Because the pairing exchange must also route through it and can run while a VHID is being republished, the tunnel is created at `.ready` for every BLE device and cleared at `.disconnected`. Non-relay modes never send through it except pairing, so behaviour is otherwise unchanged. The set-report handler captures it by value like every other Sendable local.

## File Structure

- Create: `WaveBird/Bridge/CommandTunnel.swift` — actor serialising `Transport.sendAwaitingResponse` per device.
- Create: `WaveBird/HID/NS2RelayOutputProfile.swift` — `NS2RelayOutput` (profile + session) with the three pure transforms and the descriptor helpers.
- Create: `WaveBirdTests/NS2RelayTests.swift` — golden-byte tests for transforms, descriptors, and tunnel serialisation.
- Modify: `WaveBird/HID/HIDOutputProfile.swift` — add `relayCommand` hook + default; swap catalog entries; delete `NS2PassthroughOutput`.
- Delete: `WaveBird/HID/Switch2ProSDLOutputProfile.swift`.
- Modify: `WaveBird/HID/VirtualHIDDevice.swift` — replace `ns2VendorDescriptor` with `ns2RelayDescriptor(rumbleOutputReportID:)` and add `ns2TunnelDescriptorBlock`.
- Modify: `WaveBird/Profiles/ProControllerProfile.swift`, `GameCubeProfile.swift`, `JoyConProfile.swift`, `JoyConPairProfile.swift`, `WaveBird/Core/ControllerProfile.swift` — rename `vendorPassthroughDescriptor` → `relayDescriptor` and update bodies.
- Modify: `WaveBird/Bridge/DeviceRecord.swift` — `commandTunnel: CommandTunnel?`.
- Modify: `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift` — create/clear the tunnel on `.ready`/`.disconnected`.
- Modify: `WaveBird/Bridge/BridgeCoordinator+OutputMode.swift` — pass tunnel into the set-report handler; tunnel branch; raw-rumble watchdog.
- Modify: `WaveBird/Pairing/NS2Pairing.swift`, `WaveBird/Bridge/BridgeCoordinator+Pairing.swift` — pairing sends through the tunnel.
- Modify: `WaveBird/Bridge/BridgeCoordinator+JoyConPair.swift`, `WaveBird/UI/ProfilePickerSheet.swift` — keep relay out of the merged pair's preference lookup and picker.
- Modify: `WaveBirdTests/MappingTests.swift` — `debugOnlyModesHaveNoCatalog` references `ns2Relay`.
- Modify: `CLAUDE.md` — catalog line, secondary-inputs line, relay paragraph.

---

### Task 1: `CommandTunnel` actor

**Files:**
- Create: `WaveBird/Bridge/CommandTunnel.swift`
- Test: `WaveBirdTests/NS2RelayTests.swift`

**Interfaces:**
- Consumes: `Transport.sendAwaitingResponse(_:to:timeout:) async throws -> CommandResponseFrame?` (`WaveBird/Transports/Transport.swift`), `DeviceID`, `CommandResponseFrame` (`Core/TransportEvent.swift`).
- Produces: `actor CommandTunnel { init(transport: any Transport, deviceID: DeviceID); func send(_ frame: Data, timeout: Duration) async throws -> CommandResponseFrame? }`. Calls to `send` on one instance are executed strictly one after another; the next begins only after the previous has returned (or thrown).

- [ ] **Step 1: Write the failing test**

Create `WaveBirdTests/NS2RelayTests.swift`:

```swift
import CoreHID
import Foundation
import Testing
@testable import WaveBird

// Minimal Transport that records overlap. `Transport` is WaveBird's own
// protocol (not an OS type), so a fake here doesn't violate the no-mocking
// rule in CLAUDE.md — it exists only to prove the tunnel serialises.
actor OverlapRecordingTransport: Transport {
    nonisolated let kind: TransportKind = .ble
    nonisolated let events: AsyncStream<TransportEvent> = AsyncStream { _ in }

    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var order: [UInt8] = []

    func startDiscovery(matchers: [TransportMatcher]) async {}
    func stopDiscovery() async {}
    func connect(_ id: DeviceID) async throws {}
    func disconnect(_ id: DeviceID) async {}
    func send(_ payload: Data, reportID: UInt8?, to id: DeviceID) async throws {}

    func sendAwaitingResponse(_ payload: Data, to id: DeviceID, timeout: Duration) async throws -> CommandResponseFrame? {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        order.append(payload[payload.startIndex])
        try? await Task.sleep(for: .milliseconds(20))
        inFlight -= 1
        return CommandResponseFrame(data: Data([payload[payload.startIndex], 0x01, 0x01, 0x00, 0x10, 0x78]), sourceHandle: 0x001A)
    }
}

struct CommandTunnelTests {

    @Test func concurrentSendsNeverOverlapAndKeepOrder() async throws {
        let transport = OverlapRecordingTransport()
        let id = DeviceID(transport: .ble, raw: UUID())
        let tunnel = CommandTunnel(transport: transport, deviceID: id)

        // Fire five sends without awaiting between them, then collect.
        let results = try await withThrowingTaskGroup(of: (UInt8, UInt8?).self) { group in
            for cmd: UInt8 in [1, 2, 3, 4, 5] {
                group.addTask {
                    let r = try await tunnel.send(Data([cmd, 0x91, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]), timeout: .seconds(1))
                    return (cmd, r?.data.first)
                }
                // A tiny stagger so the submission order is deterministic.
                try await Task.sleep(for: .milliseconds(1))
            }
            var out: [(UInt8, UInt8?)] = []
            for try await r in group { out.append(r) }
            return out
        }

        #expect(await transport.maxInFlight == 1)
        #expect(await transport.order == [1, 2, 3, 4, 5])
        // Every caller got its own response, not a neighbour's.
        for (cmd, echoed) in results { #expect(echoed == cmd) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/CommandTunnelTests`
Expected: build FAILS with `cannot find 'CommandTunnel' in scope`.

- [ ] **Step 3: Write the actor**

Create `WaveBird/Bridge/CommandTunnel.swift`:

```swift
import Foundation

// Serialises every post-.ready sendAwaitingResponse for one device.
// BLETransport keeps a single pending continuation per peripheral and
// preconditions against overlap; CoreHID can deliver set-reports
// concurrently and the LTK pairing exchange can run at any time after
// .ready, so anything that awaits a command response goes through here.
//
// An actor's methods are re-entrant across suspension points, so isolation
// alone doesn't serialise the awaited transport call — each send chains on
// the previous one's task instead. The chained task is unstructured on
// purpose: a cancelled caller must not abandon a BLE command mid-flight.
actor CommandTunnel {
    private let transport: any Transport
    private let deviceID: DeviceID
    private var tail: Task<Void, Never>?

    init(transport: any Transport, deviceID: DeviceID) {
        self.transport = transport
        self.deviceID = deviceID
    }

    func send(_ frame: Data, timeout: Duration) async throws -> CommandResponseFrame? {
        let previous = tail
        let transport = self.transport
        let deviceID = self.deviceID
        let task = Task<CommandResponseFrame?, any Error> {
            await previous?.value
            return try await transport.sendAwaitingResponse(frame, to: deviceID, timeout: timeout)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/CommandTunnelTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add WaveBird/Bridge/CommandTunnel.swift WaveBirdTests/NS2RelayTests.swift
git commit -m "bridge: add CommandTunnel to serialise awaited BLE commands

One in-flight sendAwaitingResponse per device, chained on the previous
call's task. Groundwork for the NS2 relay tunnel and for routing the LTK
exchange through the same queue."
```

---

### Task 2: Relay descriptors

**Files:**
- Modify: `WaveBird/HID/VirtualHIDDevice.swift:99-118` (replace `ns2VendorDescriptor`)
- Modify: `WaveBird/Core/ControllerProfile.swift:28-31`
- Modify: `WaveBird/Profiles/ProControllerProfile.swift:52-113`
- Modify: `WaveBird/Profiles/GameCubeProfile.swift:69`
- Modify: `WaveBird/Profiles/JoyConProfile.swift:76`
- Modify: `WaveBird/Profiles/JoyConPairProfile.swift:31`
- Test: `WaveBirdTests/NS2RelayTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `ControllerProfile.relayDescriptor: Data` (replaces `vendorPassthroughDescriptor`).
  - `VirtualHIDDevice.ns2TunnelDescriptorBlock: Data` — the exact bytes of the `0x80` out / `0x81` in tunnel block (no collection wrapper).
  - `VirtualHIDDevice.ns2RelayDescriptor(rumbleOutputReportID: UInt8) -> Data` — Game Pad collection with input `0x05`, output `rumbleOutputReportID`, and the tunnel block.

- [ ] **Step 1: Write the failing tests**

Append to `WaveBirdTests/NS2RelayTests.swift`:

```swift
// Count non-overlapping occurrences of `pattern` in `data`.
func occurrences(of pattern: Data, in data: Data) -> Int {
    guard !pattern.isEmpty, data.count >= pattern.count else { return 0 }
    var count = 0
    var i = data.startIndex
    while i <= data.endIndex - pattern.count {
        if data[i..<(i + pattern.count)].elementsEqual(pattern) {
            count += 1
            i += pattern.count
        } else {
            i += 1
        }
    }
    return count
}

struct NS2RelayDescriptorTests {

    // Report ID 0x80 declared as a 64-byte Output; 0x81 as an 80-byte Input.
    private let tunnelOut = Data([0x85, 0x80, 0x09, 0x03, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02])
    private let tunnelIn  = Data([0x85, 0x81, 0x09, 0x04, 0x95, 0x50, 0x81, 0x02])
    private let gamePadHeader = Data([0x05, 0x01, 0x09, 0x05, 0xA1, 0x01])

    @Test func tunnelBlockIsOnTheVendorPageAndDeclaresBothReports() {
        let block = VirtualHIDDevice.ns2TunnelDescriptorBlock
        #expect(block.prefix(3) == Data([0x06, 0x00, 0xFF]))  // Usage Page 0xFF00
        #expect(occurrences(of: tunnelOut, in: block) == 1)
        #expect(occurrences(of: tunnelIn, in: block) == 1)
    }

    @Test func proDescriptorIsRealUSBShapePlusOneTunnelBlock() {
        let d = ProControllerProfile().relayDescriptor
        #expect(d.prefix(6) == gamePadHeader)
        #expect(d.last == 0xC0)
        #expect(occurrences(of: VirtualHIDDevice.ns2TunnelDescriptorBlock, in: d) == 1)
        // Real Pro report set: 0x05 in, 0x09 in, 0x02 out — each declared once.
        #expect(occurrences(of: Data([0x85, 0x05]), in: d) == 1)
        #expect(occurrences(of: Data([0x85, 0x09]), in: d) == 1)
        #expect(occurrences(of: Data([0x85, 0x02, 0x09, 0x01, 0x95, 0x3F, 0x91, 0x02]), in: d) == 1)
        // The tunnel block sits inside the application collection.
        #expect(d.dropLast().suffix(VirtualHIDDevice.ns2TunnelDescriptorBlock.count) == VirtualHIDDevice.ns2TunnelDescriptorBlock)
    }

    @Test func gameCubeDescriptorDeclaresGamePadInput05Rumble03AndTunnel() {
        let d = GameCubeProfile().relayDescriptor
        #expect(d.prefix(6) == gamePadHeader)
        #expect(d.last == 0xC0)
        #expect(occurrences(of: Data([0x85, 0x05, 0x09, 0x01, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x3F, 0x81, 0x02]), in: d) == 1)
        #expect(occurrences(of: Data([0x85, 0x03, 0x09, 0x02, 0x95, 0x3F, 0x91, 0x02]), in: d) == 1)
        #expect(occurrences(of: VirtualHIDDevice.ns2TunnelDescriptorBlock, in: d) == 1)
    }

    @Test func joyConDescriptorsDeclareRumble01() {
        for side in [JoyConProfile.Side.left, .right] {
            let d = JoyConProfile(side: side).relayDescriptor
            #expect(d.prefix(6) == gamePadHeader)
            #expect(occurrences(of: Data([0x85, 0x01, 0x09, 0x02, 0x95, 0x3F, 0x91, 0x02]), in: d) == 1)
            #expect(occurrences(of: VirtualHIDDevice.ns2TunnelDescriptorBlock, in: d) == 1)
        }
    }

    @Test func relayDescriptorEmbedsTheGivenRumbleID() {
        let d = VirtualHIDDevice.ns2RelayDescriptor(rumbleOutputReportID: 0x7A)
        #expect(occurrences(of: Data([0x85, 0x7A, 0x09, 0x02, 0x95, 0x3F, 0x91, 0x02]), in: d) == 1)
        #expect(occurrences(of: Data([0x85, 0x05]), in: d) == 1)
        #expect(d.first == 0x05 && d.last == 0xC0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/NS2RelayDescriptorTests`
Expected: build FAILS with `has no member 'relayDescriptor'` / `'ns2TunnelDescriptorBlock'`.

- [ ] **Step 3: Replace `ns2VendorDescriptor` in `VirtualHIDDevice.swift`**

Replace the whole `extension VirtualHIDDevice { static func ns2VendorDescriptor ... }` block (lines 99–118) with:

```swift
extension VirtualHIDDevice {
    // Tunnel reports for the NS2 relay mode (spec: docs/superpowers/specs/
    // 2026-09-10-ns2-relay-design.md §"The HID contract"). Appended inside a
    // Game Pad application collection; sets its own usage page so it is
    // independent of whatever page precedes it.
    //   0x80 Output, 64 bytes — command request frame (SDL → controller)
    //   0x81 Input,  80 bytes — command response frame (controller → SDL)
    static let ns2TunnelDescriptorBlock: Data = Data([
        0x06, 0x00, 0xFF,        // Usage Page (Vendor 0xFF00)
        0x85, 0x80,              // Report ID (0x80)
        0x09, 0x03,              // Usage (Vendor 0x03 — command request)
        0x15, 0x00,              // Logical Minimum (0)
        0x26, 0xFF, 0x00,        // Logical Maximum (255)
        0x75, 0x08,              // Report Size (8)
        0x95, 0x40,              // Report Count (64)
        0x91, 0x02,              // Output (Data, Var, Abs)
        0x85, 0x81,              // Report ID (0x81)
        0x09, 0x04,              // Usage (Vendor 0x04 — command response)
        0x95, 0x50,              // Report Count (80)
        0x81, 0x02,              // Input (Data, Var, Abs)
    ])

    // Relay descriptor for controllers whose real USB descriptor we don't
    // carry (GC, Joy-Con). The Generic Desktop / Game Pad outer collection is
    // load-bearing: SDL's HIDAPI_IGNORE_DEVICE drops any device whose top-level
    // usage isn't Joystick/Game Pad/Multi-axis when
    // SDL_HINT_HIDAPI_ENUMERATE_ONLY_CONTROLLERS is on (the default).
    //   0x05 Input,  63 bytes — controller state (BLE Report 0x05 verbatim)
    //   rumbleOutputReportID Output, 63 bytes — native rumble packet
    //   + ns2TunnelDescriptorBlock
    static func ns2RelayDescriptor(rumbleOutputReportID: UInt8) -> Data {
        var d = Data([
            0x05, 0x01,              // Usage Page (Generic Desktop)
            0x09, 0x05,              // Usage (Game Pad)
            0xA1, 0x01,              // Collection (Application)
            0x06, 0x00, 0xFF,        //   Usage Page (Vendor 0xFF00)
            0x85, 0x05,              //   Report ID (5)
            0x09, 0x01,              //   Usage (Vendor 0x01 — state)
            0x15, 0x00,              //   Logical Minimum (0)
            0x26, 0xFF, 0x00,        //   Logical Maximum (255)
            0x75, 0x08,              //   Report Size (8)
            0x95, 0x3F,              //   Report Count (63)
            0x81, 0x02,              //   Input (Data, Var, Abs)
            0x85, rumbleOutputReportID, // Report ID (rumble)
            0x09, 0x02,              //   Usage (Vendor 0x02 — rumble)
            0x95, 0x3F,              //   Report Count (63)
            0x91, 0x02,              //   Output (Data, Var, Abs)
        ])
        d.append(ns2TunnelDescriptorBlock)
        d.append(0xC0)               // End Collection
        return d
    }
}
```

- [ ] **Step 4: Rename the protocol requirement in `ControllerProfile.swift`**

Replace lines 28–31:

```swift
    // Vendor passthrough descriptor: declares a single vendor input report
    // (usage page 0xFF00, report ID 0x05, 63 bytes) for ns2Passthrough mode.
    var vendorPassthroughDescriptor: Data { get }
```

with:

```swift
    // HID descriptor the ns2Relay output mode publishes for this controller:
    // the real NS2 report set (state in, native rumble out) plus the 0x80/0x81
    // command tunnel. See VirtualHIDDevice.ns2RelayDescriptor.
    var relayDescriptor: Data { get }
```

- [ ] **Step 5: Update the Pro descriptor**

In `WaveBird/Profiles/ProControllerProfile.swift`, replace the comment + property at lines 52–57:

```swift
    // Verbatim from the physical Switch 2 Pro Controller over USB (extracted via
    // ioreg with the device plugged in). Two input reports + one output:
    //   Report 5  (in,  63 vendor bytes)               — subcommand / handshake replies
    //   Report 9  (in,  2 vendor + 21 btn + 4×12b axes + 52 vendor = 63 bytes) — state
    //   Report 2  (out, 63 vendor bytes)               — host writes (rumble / subcommands)
    // Used by ns2Passthrough mode so apps that key off the Switch 2 Pro USB
    // descriptor see the same shape over BLE.
    var vendorPassthroughDescriptor: Data { Self.usbPassthroughDescriptor }
```

with:

```swift
    // Verbatim from the physical Switch 2 Pro Controller over USB (extracted via
    // ioreg with the device plugged in). Two input reports + one output:
    //   Report 5  (in,  63 vendor bytes)               — state (what relay emits)
    //   Report 9  (in,  2 vendor + 21 btn + 4×12b axes + 52 vendor = 63 bytes) — declared for fidelity, never emitted
    //   Report 2  (out, 63 vendor bytes)               — native rumble
    // Relay appends the 0x80/0x81 command tunnel inside the same collection.
    var relayDescriptor: Data {
        var d = Self.usbDescriptor
        d.removeLast()                                   // End Collection
        d.append(VirtualHIDDevice.ns2TunnelDescriptorBlock)
        d.append(0xC0)
        return d
    }
```

Then rename the constant on line 59 from `private static let usbPassthroughDescriptor: Data = Data([` to `private static let usbDescriptor: Data = Data([`. The byte table itself is untouched.

- [ ] **Step 6: Update GC, Joy-Con, and pair profiles**

`WaveBird/Profiles/GameCubeProfile.swift` line 69 — replace:

```swift
    var vendorPassthroughDescriptor: Data { VirtualHIDDevice.ns2VendorDescriptor(reportID: 0x05, byteCount: 63) }
```

with:

```swift
    // Native rumble is Output Report 0x03 (see encodeRumble below).
    var relayDescriptor: Data { VirtualHIDDevice.ns2RelayDescriptor(rumbleOutputReportID: 0x03) }
```

`WaveBird/Profiles/JoyConProfile.swift` line 76 — replace:

```swift
    var vendorPassthroughDescriptor: Data { VirtualHIDDevice.ns2VendorDescriptor(reportID: 0x05, byteCount: 63) }
```

with:

```swift
    // Native rumble is Output Report 0x01 for both sides (JoyConSharedRumble).
    var relayDescriptor: Data { VirtualHIDDevice.ns2RelayDescriptor(rumbleOutputReportID: 0x01) }
```

`WaveBird/Profiles/JoyConPairProfile.swift` line 31 — replace:

```swift
    var vendorPassthroughDescriptor: Data { VirtualHIDDevice.ns2VendorDescriptor(reportID: 0x05, byteCount: 63) }
```

with:

```swift
    // The merged pair never relays (SDL combines two relayed Joy-Cons itself);
    // this only satisfies the protocol requirement.
    var relayDescriptor: Data { VirtualHIDDevice.ns2RelayDescriptor(rumbleOutputReportID: 0x02) }
```

- [ ] **Step 7: Fix the one remaining caller**

`WaveBird/HID/HIDOutputProfile.swift` line 180 still reads `profile.vendorPassthroughDescriptor` inside `NS2PassthroughOutput`. Change it to `profile.relayDescriptor` for now (the whole type is deleted in Task 4).

- [ ] **Step 8: Run the tests**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/NS2RelayDescriptorTests`
Expected: PASS (5 tests).

- [ ] **Step 9: Commit**

```bash
git add WaveBird/HID/VirtualHIDDevice.swift WaveBird/Core/ControllerProfile.swift WaveBird/Profiles/ProControllerProfile.swift WaveBird/Profiles/GameCubeProfile.swift WaveBird/Profiles/JoyConProfile.swift WaveBird/Profiles/JoyConPairProfile.swift WaveBird/HID/HIDOutputProfile.swift WaveBirdTests/NS2RelayTests.swift
git commit -m "hid: relay descriptors with the 0x80/0x81 command tunnel

vendorPassthroughDescriptor becomes relayDescriptor. Pro keeps its real
USB report set; GC and Joy-Con gain a Game Pad collection (SDL's
only-controllers filter needs it), their rumble output ID, and the tunnel."
```

---

### Task 3: `NS2RelayOutput` transforms and the `relayCommand` hook

**Files:**
- Create: `WaveBird/HID/NS2RelayOutputProfile.swift`
- Modify: `WaveBird/HID/HIDOutputProfile.swift:106-162` (protocol + defaults)
- Test: `WaveBirdTests/NS2RelayTests.swift`

**Interfaces:**
- Consumes: `ControllerProfile.relayDescriptor`, `hidVendorID`, `hidProductID`, `name`; `HIDOutputProfile` / `HIDOutputSession` protocols; CoreHID `HIDReportType`, `HIDReportID`.
- Produces:
  - `HIDOutputSession.relayCommand(type: HIDReportType, id: HIDReportID?, data: Data) -> Data?` (protocol requirement, default `nil`).
  - `struct NS2RelayOutput: HIDOutputProfile, HIDOutputSession { init(profile: any ControllerProfile) }` with:
    - `transformRawReport(reportID: UInt8?, data: Data) -> Data?` → `[0x05] + payload padded to 63` for `reportID == nil`, else `nil`.
    - `rawVibrationPayload(type:id:data:) -> Data?` → for `.output` and the profile's rumble ID: 42-byte copy with byte 0 = `0x00`.
    - `relayCommand(type:id:data:) -> Data?` → for `.output` `0x80`: trimmed frame with byte 2 = `0x01`; `nil` for cmd `0x15`.
    - `static let rumbleReportID(forProductID:) -> UInt8?` (`0x2069 → 0x02`, `0x2073 → 0x03`, `0x2066`/`0x2067 → 0x01`).
    - `static let tunnelRequestReportID: UInt8 = 0x80`, `static let tunnelResponseReportID: UInt8 = 0x81`, `static let tunnelResponseLength = 80`.
    - `static func tunnelResponseReport(_ response: Data) -> Data` → `[0x81] + response` zero-padded/truncated to 80 payload bytes (81 total).

- [ ] **Step 1: Write the failing tests**

Append to `WaveBirdTests/NS2RelayTests.swift`:

```swift
struct NS2RelayTransformTests {

    private let pro = NS2RelayOutput(profile: ProControllerProfile())
    private let gc = NS2RelayOutput(profile: GameCubeProfile())
    private let jcL = NS2RelayOutput(profile: JoyConProfile(side: .left))
    private let jcR = NS2RelayOutput(profile: JoyConProfile(side: .right))

    // CoreHID hands the set-report handler the on-wire frame with the report
    // ID at index 0 (see DualSenseOutput.parseRumble offsets). Build one.
    private func setReport(_ id: UInt8, _ body: [UInt8], paddedTo total: Int) -> Data {
        var d = Data([id] + body)
        if d.count < total { d.append(Data(repeating: 0, count: total - d.count)) }
        return d
    }

    // MARK: identity

    @Test func identityIsTheRealNS2Controller() {
        #expect(pro.vendorID == 0x057E && pro.productID == 0x2069)
        #expect(gc.productID == 0x2073)
        #expect(jcL.productID == 0x2067 && jcR.productID == 0x2066)
        #expect(pro.manufacturer == "Nintendo")
        #expect(pro.descriptor == ProControllerProfile().relayDescriptor)
        #expect(pro.requiredSecondaryReportIDs.isEmpty)   // never subscribe Pro's 0x000E
    }

    // MARK: input 0x05

    @Test func bleFrameBecomesReport05PaddedTo64() {
        var frame = Data(repeating: 0xAA, count: 62)   // BLE sometimes drops a byte vs USB
        frame[0] = 0x11
        let out = pro.transformRawReport(reportID: nil, data: frame)
        #expect(out?.count == 64)
        #expect(out?.first == 0x05)
        #expect(out?[1] == 0x11)
        #expect(out?[62] == 0xAA)
        #expect(out?[63] == 0x00)   // zero pad
    }

    @Test func fullFrameIsNotTruncatedBeyond63() {
        let frame = Data(repeating: 0x5A, count: 70)
        let out = pro.transformRawReport(reportID: nil, data: frame)
        #expect(out?.count == 64)
    }

    @Test func secondaryReportsAreDropped() {
        // Pro's Report 0x09 must never reach SDL: HandleStatePacket doesn't
        // check the report ID and would parse it as garbage state.
        #expect(pro.transformRawReport(reportID: 0x09, data: Data(repeating: 0, count: 63)) == nil)
    }

    // MARK: rumble relay

    @Test func proRumbleReport02IsRelayedWithByte0Cleared() {
        // SDL UpdateRumble (Pro): [0x02, 0x50|seq, 5 LRA bytes, …, byte 0x11.. = copy of 1..6]
        var body = [UInt8](repeating: 0, count: 63)
        body[0] = 0x53; body[1] = 0x87; body[2] = 0x01; body[3] = 0x10; body[4] = 0x12; body[5] = 0x40
        for i in 0..<6 { body[0x10 + i] = body[i] }
        let out = pro.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x02), data: setReport(0x02, body, paddedTo: 64))
        #expect(out?.count == 42)   // same length ProControllerProfile.encodeRumble emits
        #expect(out?.first == 0x00)
        #expect(out?[1] == 0x53)
        #expect(out?[17] == 0x53 && out?[18] == 0x87)
    }

    @Test func gcRumbleReport03IsRelayed() {
        let body: [UInt8] = [0x51, 0x01]
        let out = gc.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x03), data: setReport(0x03, body, paddedTo: 64))
        #expect(out?.count == 42)   // same length GameCubeProfile.encodeRumble emits
        #expect(out?.prefix(3) == Data([0x00, 0x51, 0x01]))
    }

    @Test func joyConRumbleReport01IsRelayedOnBothSides() {
        let body: [UInt8] = [0x52, 0x87, 0x01, 0x10, 0x12, 0x40]
        for side in [jcL, jcR] {
            let out = side.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x01), data: setReport(0x01, body, paddedTo: 64))
            #expect(out?.count == 42)   // same length JoyConSharedRumble.encode emits
            #expect(out?.prefix(7) == Data([0x00, 0x52, 0x87, 0x01, 0x10, 0x12, 0x40]))
        }
    }

    @Test func wrongRumbleIDForTheProductIsIgnored() {
        // A GC never gets Pro's 0x02, and vice versa — the descriptor doesn't
        // declare it, but the guard is what keeps a stray frame off the LRA char.
        #expect(gc.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x02), data: setReport(0x02, [0x50], paddedTo: 64)) == nil)
        #expect(pro.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x03), data: setReport(0x03, [0x50], paddedTo: 64)) == nil)
        #expect(pro.rawVibrationPayload(type: .feature, id: HIDReportID(rawValue: 0x02), data: setReport(0x02, [0x50], paddedTo: 64)) == nil)
    }

    @Test func rumbleReportShorterThan42IsIgnored() {
        #expect(pro.rawVibrationPayload(type: .output, id: HIDReportID(rawValue: 0x02), data: Data([0x02, 0x50])) == nil)
    }

    // MARK: command tunnel

    @Test func featureMaskFrameIsTrimmedAndRetargetedToBluetooth() {
        // SDL init_sequence "Set feature output bit mask" — sent over bulk as 12 bytes.
        let usb: [UInt8] = [0x0C, 0x91, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00]
        let out = pro.relayCommand(type: .output, id: HIDReportID(rawValue: 0x80), data: setReport(0x80, usb, paddedTo: 65))
        #expect(out == Data([0x0C, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00]))
    }

    @Test func zeroLengthFrameIsEightBytes() {
        let usb: [UInt8] = [0x07, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        let out = gc.relayCommand(type: .output, id: HIDReportID(rawValue: 0x80), data: setReport(0x80, usb, paddedTo: 65))
        #expect(out == Data([0x07, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00]))
    }

    @Test func flashReadFramePreservesAddressBytes() {
        // SDL ReadFlashBlock(0x13140): subcmd 0x01 over USB (WaveBird uses 0x04 — both are relayed verbatim).
        let usb: [UInt8] = [0x02, 0x91, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00,
                            0x00, 0x00, 0x00, 0x00, 0x40, 0x31, 0x01, 0x00]
        let out = gc.relayCommand(type: .output, id: HIDReportID(rawValue: 0x80), data: setReport(0x80, usb, paddedTo: 65))
        #expect(out?.count == 16)
        #expect(out?[2] == 0x01)
        #expect(out?.suffix(4) == Data([0x40, 0x31, 0x01, 0x00]))
    }

    @Test func pairingCommandIsDropped() {
        let usb: [UInt8] = [0x15, 0x91, 0x00, 0x01, 0x00, 0x0E, 0x00, 0x00,
                            0x00, 0x02, 0x81, 0xEB, 0x3A, 0xEB, 0xF1, 0x48, 0x80, 0xEB, 0x3A, 0xEB, 0xF1, 0x48]
        #expect(pro.relayCommand(type: .output, id: HIDReportID(rawValue: 0x80), data: setReport(0x80, usb, paddedTo: 65)) == nil)
    }

    @Test func nonTunnelReportsAreNotCommands() {
        #expect(pro.relayCommand(type: .output, id: HIDReportID(rawValue: 0x02), data: setReport(0x02, [0x50], paddedTo: 64)) == nil)
        #expect(pro.relayCommand(type: .feature, id: HIDReportID(rawValue: 0x80), data: setReport(0x80, [0x07, 0x91, 0x00, 0x01, 0, 0, 0, 0], paddedTo: 65)) == nil)
        #expect(pro.relayCommand(type: .output, id: nil, data: setReport(0x80, [0x07, 0x91, 0x00, 0x01, 0, 0, 0, 0], paddedTo: 65)) == nil)
    }

    @Test func truncatedTunnelReportIsIgnored() {
        // Declared len 0x14 but only 10 payload bytes present.
        let short = Data([0x80, 0x0A, 0x91, 0x00, 0x08, 0x00, 0x14, 0x00, 0x00, 0x01, 0xFF])
        #expect(pro.relayCommand(type: .output, id: HIDReportID(rawValue: 0x80), data: short) == nil)
    }

    @Test func responseReportIs81BytesWithID81() {
        let resp = Data([0x0C, 0x01, 0x01, 0x02, 0x10, 0x78, 0x00, 0x00, 0x01])
        let out = NS2RelayOutput.tunnelResponseReport(resp)
        #expect(out.count == 81)
        #expect(out.first == 0x81)
        #expect(out[1..<10] == resp)
        #expect(out[10] == 0)
        // An 80-byte flash-read response fits exactly; anything longer is cut, never overflowed.
        #expect(NS2RelayOutput.tunnelResponseReport(Data(repeating: 1, count: 90)).count == 81)
    }

    @Test func rumbleIDTable() {
        #expect(NS2RelayOutput.rumbleReportID(forProductID: 0x2069) == 0x02)
        #expect(NS2RelayOutput.rumbleReportID(forProductID: 0x2073) == 0x03)
        #expect(NS2RelayOutput.rumbleReportID(forProductID: 0x2067) == 0x01)
        #expect(NS2RelayOutput.rumbleReportID(forProductID: 0x2066) == 0x01)
        #expect(NS2RelayOutput.rumbleReportID(forProductID: 0x2009) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/NS2RelayTransformTests`
Expected: build FAILS with `cannot find 'NS2RelayOutput' in scope`.

- [ ] **Step 3: Add the `relayCommand` hook to `HIDOutputSession`**

In `WaveBird/HID/HIDOutputProfile.swift`, after the `rawVibrationPayload` declaration inside `protocol HIDOutputSession` (line 150), add:

```swift

    // Command-tunnel hook for the NS2 relay mode. Returning non-nil hands the
    // coordinator a BLE command frame to send through the device's
    // CommandTunnel; the response (if any) is dispatched back as Input Report
    // 0x81. Default nil — no other presentation tunnels commands.
    func relayCommand(type: HIDReportType, id: HIDReportID?, data: Data) -> Data?
```

and in the `extension HIDOutputSession` defaults (after line 161) add:

```swift
    func relayCommand(type: HIDReportType, id: HIDReportID?, data: Data) -> Data? { nil }
```

Also update the two stale comments in the protocol: on lines 84–90 replace `Default empty — only ns2Passthrough consumes Pro's Report 0x09.` with `Default empty — no shipping or DEBUG presentation consumes one today; ns2Relay explicitly must not (Report 0x09 suppresses 0x05).` On lines 139–150, replace `Raw transport-report forwarding hook for passthrough modes.` with `Raw transport-report forwarding hook for the relay mode.` and `Used by ns2Passthrough to relay Nintendo's native Output Report 0x02` with `Used by ns2Relay to forward Nintendo's native rumble Output Report (0x01/0x02/0x03)`.

- [ ] **Step 4: Write `NS2RelayOutputProfile.swift`**

Create `WaveBird/HID/NS2RelayOutputProfile.swift`:

```swift
import CoreHID
import Foundation

// NS2 relay: the virtual device IS the controller. Real VID/PID, the real
// report set, and a vendor tunnel (0x80 out / 0x81 in) that carries SDL's
// Switch 2 driver commands to the BLE command characteristic. WaveBird moves
// bytes; SDL owns the protocol. Contract: docs/superpowers/specs/
// 2026-09-10-ns2-relay-design.md §"The HID contract" (mirrored verbatim in
// SDL's InitVirtual header comment).
//
// Stateless: every transform is a pure function of the report bytes, so
// makeSession returns self. Set-report `data` arrives with the report ID at
// index 0 (CoreHID's on-wire framing — see DualSenseOutput.parseRumble).
struct NS2RelayOutput: HIDOutputProfile, HIDOutputSession {
    let profile: any ControllerProfile

    static let tunnelRequestReportID: UInt8 = 0x80
    static let tunnelResponseReportID: UInt8 = 0x81
    static let tunnelResponseLength = 80
    // Every NS2 rumble encoder in WaveBird emits 42 bytes; the controller
    // accepts exactly that from us, so the relayed packet is cut to match.
    static let rumblePayloadLength = 42
    static let stateReportLength = 63

    var vendorID: UInt16      { profile.hidVendorID }
    var productID: UInt16     { profile.hidProductID }
    var productName: String   { profile.name }
    var manufacturer: String? { "Nintendo" }
    var versionNumber: UInt16 { 0x0001 }
    var descriptor: Data      { profile.relayDescriptor }

    func makeSession(deviceSerial: String?) -> any HIDOutputSession { self }

    // transformRawReport short-circuits every report, so this never runs.
    func buildReport(_ state: ControllerState) async -> Data { Data() }

    // Native rumble Output Report ID per controller (SDL UpdateRumble:
    // rumble_data[0] = 0x1 Joy-Con, 0x2 Pro, 0x3 GC).
    static func rumbleReportID(forProductID pid: UInt16) -> UInt8? {
        switch pid {
        case 0x2069: 0x02
        case 0x2073: 0x03
        case 0x2066, 0x2067: 0x01
        default: nil
        }
    }

    // Shared input handle 0x000A (unprefixed on BLE) → Input Report 0x05,
    // padded to the descriptor's 63 bytes when BLE truncates. Byte-identical
    // to the controller's USB HID input, so SDL's parser needs no change.
    // Anything with a report ID is a secondary channel — never forwarded.
    func transformRawReport(reportID: UInt8?, data: Data) -> Data? {
        guard reportID == nil else { return nil }
        var out = Data([0x05])
        out.append(data.prefix(Self.stateReportLength))
        if out.count < Self.stateReportLength + 1 {
            out.append(Data(repeating: 0, count: Self.stateReportLength + 1 - out.count))
        }
        return out
    }

    // Host rumble report for this controller → vibration characteristic,
    // verbatim except byte 0 (the HID report ID) becomes 0x00, the BLE
    // framing byte. SDL packs the LRA ops in the layout WaveBird's own
    // encoders use, so nothing is re-encoded.
    func rawVibrationPayload(type: HIDReportType, id: HIDReportID?, data: Data) -> Data? {
        guard type == .output,
              let expected = Self.rumbleReportID(forProductID: profile.hidProductID),
              id?.rawValue == expected,
              data.count >= Self.rumblePayloadLength
        else { return nil }
        var payload = Data(data.prefix(Self.rumblePayloadLength))
        payload[payload.startIndex] = 0x00
        return payload
    }

    // Output Report 0x80 → BLE command frame. SDL sends exactly `8 + len`
    // bytes over bulk (init_sequence[i][5] + 8); the rest of the report is
    // zero padding, so it is cut here. Byte 2 is the transport marker: SDL
    // writes 0x00 (USB); every hardware-validated WaveBird frame uses 0x01.
    // Cmd 0x15 (LTK pairing) is dropped — a host must never rewrite the key.
    func relayCommand(type: HIDReportType, id: HIDReportID?, data: Data) -> Data? {
        guard type == .output, id?.rawValue == Self.tunnelRequestReportID else { return nil }
        let frame = data.dropFirst()
        guard frame.count >= 8 else { return nil }
        let f = frame.startIndex
        let length = 8 + Int(frame[f + 5])
        guard frame.count >= length else { return nil }
        if frame[f] == 0x15 {
            stderrLog("[relay] dropped cmd 0x15 (pairing) from host")
            return nil
        }
        var out = Data(frame.prefix(length))
        out[out.startIndex + 2] = 0x01
        return out
    }

    // Response frame → Input Report 0x81, zero-padded to the declared 80
    // bytes. Responses are never modified (SDL doesn't read byte 2).
    static func tunnelResponseReport(_ response: Data) -> Data {
        var out = Data([tunnelResponseReportID])
        out.append(response.prefix(tunnelResponseLength))
        if out.count < tunnelResponseLength + 1 {
            out.append(Data(repeating: 0, count: tunnelResponseLength + 1 - out.count))
        }
        return out
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/NS2RelayTransformTests`
Expected: PASS (17 tests).

- [ ] **Step 6: Commit**

```bash
git add WaveBird/HID/NS2RelayOutputProfile.swift WaveBird/HID/HIDOutputProfile.swift WaveBirdTests/NS2RelayTests.swift
git commit -m "hid: NS2RelayOutput transforms + relayCommand session hook

Pure byte transforms for the relay contract: 0x05 framing, native rumble
relay for 0x01/0x02/0x03, tunnel-frame trimming with the BLE transport
byte, 0x15 denylist, 0x81 response framing. Golden tests pin each."
```

---

### Task 4: Catalog swap and precursor deletion

**Files:**
- Modify: `WaveBird/HID/HIDOutputProfile.swift:63-72` (catalog), after `:73` (pair-exclusion helper), and `:164-243` (delete `NS2PassthroughOutput`)
- Delete: `WaveBird/HID/Switch2ProSDLOutputProfile.swift`
- Modify: `WaveBird/Bridge/BridgeCoordinator+JoyConPair.swift:176-177` (`formJoyConPair` preference lookup)
- Modify: `WaveBird/UI/ProfilePickerSheet.swift:33` (+ `availableProfiles`)
- Modify: `WaveBirdTests/MappingTests.swift:78-81`
- Modify: `WaveBird/Profiles/ProControllerProfile.swift:14-20` (comment only)
- Modify: `WaveBird/Bridge/BridgeCoordinator+OutputMode.swift:133-135`, `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift:276-279`, `WaveBird/Transports/Transport.swift:15-19`, `WaveBird/Transports/BLE/BLETransport.swift:33-35,350` (comments only)
- Test: `WaveBirdTests/NS2RelayTests.swift`

**Interfaces:**
- Consumes: `NS2RelayOutput(profile:)` from Task 3.
- Produces: catalog entry `id: "ns2Relay"`, `displayName: "NS2 Relay (SDL)"` under `#if DEBUG`; `ns2Passthrough` and `switch2ProSDL` no longer exist anywhere; `HIDOutputCatalog.pairExcludedModeIDs: Set<String>` and `HIDOutputCatalog.pairSelectableProfiles(from: [MappingProfile]) -> [MappingProfile]`.

- [ ] **Step 1: Write the failing tests**

Append to `WaveBirdTests/NS2RelayTests.swift`:

```swift
struct NS2RelayCatalogTests {

    @Test func relayIsInTheDebugCatalogAndNotAllowListed() {
        let catalog = HIDOutputCatalog.default
        #if DEBUG
        let entry = catalog.entry(id: "ns2Relay")
        #expect(entry?.displayName == "NS2 Relay (SDL)")
        #expect(entry?.makeProfile(GameCubeProfile()) is NS2RelayOutput)
        #else
        #expect(catalog.entry(id: "ns2Relay") == nil)
        #endif
        #expect(!HIDOutputCatalog.allowListIDs.contains("ns2Relay"))
        #expect(catalog.entry(id: "ns2Passthrough") == nil)
        #expect(catalog.entry(id: "switch2ProSDL") == nil)
    }

    @Test func removedModeIDsResolveToTheDefaultShippingMode() {
        // Persisted preferences naming the deleted modes must degrade, not crash.
        let catalog = HIDOutputCatalog.default
        #expect(catalog.resolved(id: "ns2Passthrough").id == catalog.firstAllowListedID)
        #expect(catalog.resolved(id: "switch2ProSDL").id == catalog.firstAllowListedID)
    }

    @Test func relayHasNoMappingControls() {
        // Relay bypasses buildReport; mapping is meaningless there.
        #expect(MappingControls.controls(forModeID: "ns2Relay").isEmpty)
    }

    @Test func pairPickerHidesRelayProfiles() {
        // The merged Joy-Con pair never relays. The filter is by base mode ID.
        let store = MappingProfileStore(catalog: .default, defaults: UserDefaults(suiteName: "NS2RelayCatalogTests")!)
        let visible = HIDOutputCatalog.pairSelectableProfiles(from: store.builtInProfiles + store.customProfiles)
        #expect(!visible.contains { $0.baseModeID == "ns2Relay" })
        #expect(visible.contains { $0.baseModeID == "switchPro" })
    }
}
```

In `WaveBirdTests/MappingTests.swift`, replace lines 78–81:

```swift
    @Test func debugOnlyModesHaveNoCatalog() {
        // Passthrough bypasses buildReport entirely; mapping is meaningless there.
        #expect(MappingControls.controls(forModeID: "ns2Passthrough").isEmpty)
    }
```

with:

```swift
    @Test func debugOnlyModesHaveNoCatalog() {
        // Relay bypasses buildReport entirely; mapping is meaningless there.
        #expect(MappingControls.controls(forModeID: "ns2Relay").isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests/NS2RelayCatalogTests`
Expected: `relayIsInTheDebugCatalogAndNotAllowListed` FAILS (`entry?.displayName == nil`, and the passthrough/switch2ProSDL entries still exist).

- [ ] **Step 3: Swap the catalog entries**

In `WaveBird/HID/HIDOutputProfile.swift`, replace lines 67–70:

```swift
        #if DEBUG
        entries.append(Entry(id: "ns2Passthrough", displayName: "NS2 Passthrough (raw)") { NS2PassthroughOutput(profile: $0) })
        entries.append(Entry(id: "switch2ProSDL", displayName: "Switch 2 Pro (SDL)") { _ in Switch2ProSDLOutput() })
        #endif
```

with:

```swift
        #if DEBUG
        // DEBUG-only until a released SDL carries the virtual transport: a
        // stock SDL app would see a raw NS2 it cannot initialise.
        entries.append(Entry(id: "ns2Relay", displayName: "NS2 Relay (SDL)") { NS2RelayOutput(profile: $0) })
        #endif
```

- [ ] **Step 3b: Keep relay away from the merged Joy-Con pair**

The pair form path takes whichever side's stored profile it finds first, and `catalog.resolved` accepts any ID — so a side whose per-serial preference is `default.ns2Relay` would otherwise hand `JoyConPairProfile` to the relay factory. Guard by base mode ID in one place and use it from both the coordinator and the picker.

In `WaveBird/HID/HIDOutputProfile.swift`, after the `HIDOutputCatalog` struct's closing brace (line 73), add:

```swift
extension HIDOutputCatalog {
    // Modes the merged Joy-Con pair may never use. SDL combines two relayed
    // Joy-Cons itself, and JoyConPairProfile has no real identity to relay.
    static let pairExcludedModeIDs: Set<String> = ["ns2Relay"]

    static func pairSelectableProfiles(from profiles: [MappingProfile]) -> [MappingProfile] {
        profiles.filter { !pairExcludedModeIDs.contains($0.baseModeID) }
    }
}
```

In `WaveBird/Bridge/BridgeCoordinator+JoyConPair.swift`, `formJoyConPair` (lines 176–177), replace:

```swift
        let storedProfileID: String? = left.serial.flatMap { knownControllers[$0]?.resolvedProfileID }
            ?? right.serial.flatMap { knownControllers[$0]?.resolvedProfileID }
```

with:

```swift
        // A side whose solo preference is relay contributes nothing here; the
        // pair falls through to the picker (or the other side's preference).
        let storedProfileID: String? = [left.serial, right.serial]
            .compactMap { $0.flatMap { knownControllers[$0]?.resolvedProfileID } }
            .first { !HIDOutputCatalog.pairExcludedModeIDs.contains(resolveMappingProfile(id: $0).baseModeID) }
```

In `WaveBird/UI/ProfilePickerSheet.swift` line 33, replace:

```swift
                ForEach(coordinator.mappingProfiles.builtInProfiles + coordinator.mappingProfiles.customProfiles) { profile in
```

with:

```swift
                ForEach(availableProfiles) { profile in
```

and add inside `ProfilePickerSheet` (after `init`):

```swift
    // A pair-keyed picker (L's row while the pair forms) hides relay profiles.
    private var availableProfiles: [MappingProfile] {
        let all = coordinator.mappingProfiles.builtInProfiles + coordinator.mappingProfiles.customProfiles
        guard coordinator.joyConPair?.includes(deviceID) == true else { return all }
        return HIDOutputCatalog.pairSelectableProfiles(from: all)
    }
```

- [ ] **Step 4: Delete the precursors**

In `WaveBird/HID/HIDOutputProfile.swift`, delete everything from the line `// MARK: - NS2 raw passthrough` (line 164) through the closing brace of `struct NS2PassthroughOutput` (line 243, the `}` before `// MARK: - Stick / hat helpers`).

Delete the file:

```bash
git rm WaveBird/HID/Switch2ProSDLOutputProfile.swift
```

- [ ] **Step 5: Fix the stale comments that name the deleted modes**

Each is comment-only; no code changes:

- `WaveBird/Profiles/ProControllerProfile.swift:14-20` — replace the four-line comment ending `descriptor's structured button/axis report.` with:
  ```swift
        // Pro's per-controller input handle (0x000E) delivers Report 0x09 —
        // the same sticks/buttons as Report 0x05 plus battery + motion. Listed
        // as the catalog of available channels only: nothing subscribes it
        // (subscribing suppresses 0x05 — see CLAUDE.md).
  ```
- `WaveBird/Bridge/BridgeCoordinator+OutputMode.swift:133-135` — replace `(e.g. ns2Passthrough wants Pro's Report 0x09)` with `(none today; relay explicitly needs none)`.
- `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift:276-279` — replace the comment block starting `// Raw-forwarding session path (ns2Passthrough):` with:
  ```swift
            // Raw-forwarding session path (ns2Relay): dispatch the transport
            // bytes verbatim under the right HID report ID, bypassing parsing.
  ```
- `WaveBird/Transports/Transport.swift:18` — replace `— e.g. only ns2Passthrough wants Pro's Report 0x09 on handle 0x000E.` with `— none of the current modes subscribes one.`
- `WaveBird/Transports/BLE/BLETransport.swift:33-35` and `:350` — replace `ns2Passthrough` with `an output mode` in both comments.
- `WaveBird/Core/ControllerProfile.swift:136-137` — replace `(used by ns2Passthrough)` with `(none subscribed today)`.

Run `grep -rn "ns2Passthrough\|switch2ProSDL\|NS2PassthroughOutput\|Switch2ProSDLOutput\|vendorPassthroughDescriptor\|ns2VendorDescriptor" WaveBird WaveBirdTests` — expected: no output.

- [ ] **Step 6: Build and run the whole unit suite**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS, all suites.

- [ ] **Step 7: Commit**

```bash
git add -A WaveBird/HID WaveBird/Profiles/ProControllerProfile.swift WaveBird/Bridge WaveBird/Transports WaveBird/Core/ControllerProfile.swift WaveBird/UI/ProfilePickerSheet.swift WaveBirdTests
git commit -m "hid: replace ns2Passthrough + switch2ProSDL with ns2Relay

One DEBUG-only catalog entry. Persisted preferences naming the removed
modes fall back through resolved(id:) — no migration. The merged Joy-Con
pair never resolves to relay (pairExcludedModeIDs)."
```

---

### Task 5: Coordinator wiring — tunnel lifetime, set-report branch, raw-rumble watchdog

**Files:**
- Modify: `WaveBird/Bridge/DeviceRecord.swift:36-43`
- Modify: `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift:151-157` (`.ready`) and `:245-273` (`.disconnected`)
- Modify: `WaveBird/Bridge/BridgeCoordinator+OutputMode.swift:142-165` (`makeVirtualHID`), `:206-300` (`makeSetReportHandler`)

**Interfaces:**
- Consumes: `CommandTunnel` (Task 1), `NS2RelayOutput.tunnelResponseReport(_:)` (Task 3), `HIDOutputSession.relayCommand` (Task 3).
- Produces:
  - `DeviceRecord.commandTunnel: CommandTunnel?` — non-nil from `.ready` until `.disconnected` for every BLE device.
  - `makeSetReportHandler(id:transport:profile:rumbleRefresh:session:settings:tunnel:)` — new trailing `tunnel: CommandTunnel?` parameter.

- [ ] **Step 1: Add the tunnel to `DeviceRecord`**

In `WaveBird/Bridge/DeviceRecord.swift`, after the `session` property (line 42), add:

```swift
    // Serialises every post-.ready awaited command (relay tunnel, LTK
    // pairing) for this connection. Created at .ready, dropped at
    // .disconnected — outlives any one VHID so a republish can't strand a
    // pairing exchange in flight.
    var commandTunnel: CommandTunnel?
```

- [ ] **Step 2: Create and clear it in the event handler**

In `WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift`, in `case .ready(let id):` after `activityTracker.seed(id)` (line 156) and before `guard let record = devices[id] else { return }`, add:

```swift
            if let t = transport(for: kind) {
                devices[id]?.commandTunnel = CommandTunnel(transport: t, deviceID: id)
            }
```

In `case .disconnected(let id, _):`, after `devices[id]?.session = nil` (line 273), add:

```swift
            devices[id]?.commandTunnel = nil
```

- [ ] **Step 3: Pass the tunnel into the set-report handler**

In `WaveBird/Bridge/BridgeCoordinator+OutputMode.swift`, `makeVirtualHID` (line 148), change:

```swift
        let onSetReport = makeSetReportHandler(id: record.id, transport: transport(for: record.id.transport), profile: record.profile, rumbleRefresh: rumbleBox, session: session, settings: settings)
```

to:

```swift
        let onSetReport = makeSetReportHandler(id: record.id, transport: transport(for: record.id.transport), profile: record.profile, rumbleRefresh: rumbleBox, session: session, settings: settings, tunnel: record.commandTunnel)
```

Change the signature of `makeSetReportHandler` (lines 206–213) to:

```swift
    func makeSetReportHandler(
        id deviceID: DeviceID,
        transport: (any Transport)?,
        profile: any ControllerProfile,
        rumbleRefresh: RumbleRefreshBox,
        session: any HIDOutputSession,
        settings: RumbleSettings,
        tunnel: CommandTunnel?
    ) -> VirtualHIDDevice.SetReportHandler {
```

- [ ] **Step 4: Add the tunnel branch and the raw-rumble watchdog**

Inside the returned closure, replace the block from `// Passthrough modes can hand us a pre-formed BLE vibration payload.` through its `return\n            }` (lines 219–231) with:

```swift
            // Relay tunnel: an SDL command frame for the controller. One in
            // flight per device (CommandTunnel serialises); the response, if
            // one arrives within the bridge deadline, goes back as Input
            // Report 0x81. No response → nothing is sent; SDL's own 2 s
            // deadline handles it.
            if let frame = session.relayCommand(type: type, id: id, data: data) {
                guard let tunnel else { return }
                if let response = try? await tunnel.send(frame, timeout: .seconds(1)), let response {
                    try? await device.dispatchInputReport(data: NS2RelayOutput.tunnelResponseReport(response.data), timestamp: .now)
                }
                return
            }

            // Relay rumble: the host already speaks the controller's native
            // rumble format, so send it verbatim and skip parseRumble →
            // encodeRumble (normalising through RumbleCommand would lose
            // per-band freq/amp fidelity). The host drives cadence, so any
            // in-flight refresh loop is cancelled — but the 1 s stop watchdog
            // is kept: if the host goes silent (crash, focus loss), an
            // encoded stop frame quiets the motor.
            if let payload = session.rawVibrationPayload(type: type, id: id, data: data) {
                rumbleRefresh.cancel()
                try? await transport?.sendVibration(payload, to: deviceID)
                rumbleRefresh.replace(with: Task {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    if let stop = profile.encodeRumble(RumbleCommand(), sequence: rumbleRefresh.nextCounter(), settings: settings.snapshot()) {
                        try? await transport?.sendVibration(stop, to: deviceID)
                    }
                })
                await session.handleSetReport(device: device, type: type, id: id, data: data)
                return
            }
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. (Strict concurrency: `tunnel` is an actor reference, `Sendable`, captured by value like `session`/`transport`. If the compiler complains about `device.dispatchInputReport`, it is the same call `SwitchProSession` already makes on line 115 of `SwitchProSession.swift`.)

- [ ] **Step 6: Run the unit suite**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add WaveBird/Bridge/DeviceRecord.swift WaveBird/Bridge/BridgeCoordinator+TransportEvents.swift WaveBird/Bridge/BridgeCoordinator+OutputMode.swift
git commit -m "bridge: wire the relay tunnel and raw-rumble watchdog

CommandTunnel per connection (.ready → .disconnected). Set-report handler
routes 0x80 frames through it and answers on 0x81; relayed rumble arms a
1 s encoded-stop watchdog instead of a refresh loop.

Needs hardware: Pro + GC init through SDL, rumble, watchdog."
```

---

### Task 6: Route the LTK pairing exchange through the tunnel

**Files:**
- Modify: `WaveBird/Pairing/NS2Pairing.swift:41-45,117` (and every `transport:` argument inside `run`)
- Modify: `WaveBird/Bridge/BridgeCoordinator+Pairing.swift:66-85` (`acceptPairing`)

**Interfaces:**
- Consumes: `CommandTunnel.send(_:timeout:)` (Task 1), `DeviceRecord.commandTunnel` (Task 5).
- Produces: `NS2Pairing.run(deviceID:tunnel:hostAddress:) async throws -> NS2PairingResult` — `transport:` parameter replaced by `tunnel: CommandTunnel`.

- [ ] **Step 1: Change `NS2Pairing.run` and `sendStep` to take the tunnel**

In `WaveBird/Pairing/NS2Pairing.swift`:

- Line 41–45: change the signature to

  ```swift
    static func run(
        deviceID: DeviceID,
        tunnel: CommandTunnel,
        hostAddress: Data
    ) async throws -> NS2PairingResult {
  ```

- Every `sendStep(... transport: transport, ...)` call inside `run` becomes `tunnel: tunnel`.
- Find `private static func sendStep(` (near line 100) and change its `transport: any Transport` parameter to `tunnel: CommandTunnel`.
- Line 117: change

  ```swift
        let resp = try await transport.sendAwaitingResponse(frame, to: deviceID, timeout: stepTimeout)
  ```

  to

  ```swift
        let resp = try await tunnel.send(frame, timeout: stepTimeout)
  ```

  If `deviceID` is now unused inside `sendStep`, remove that parameter and its arguments too; keep it on `run` (the pairing result and callers use it).

- [ ] **Step 2: Update `acceptPairing`**

In `WaveBird/Bridge/BridgeCoordinator+Pairing.swift`, replace lines 66–85:

```swift
    func acceptPairing() async {
        guard let prompt = pairingPrompt else { return }
        guard let transport = transport(for: prompt.deviceID.transport) else {
            pairingPrompt?.status = .failed("transport unavailable")
            return
        }
        pairingPrompt?.status = .inProgress
        do {
            _ = try await NS2Pairing.run(
                deviceID: prompt.deviceID,
                transport: transport,
                hostAddress: prompt.hostAddress
            )
```

with:

```swift
    func acceptPairing() async {
        guard let prompt = pairingPrompt else { return }
        // The tunnel exists from .ready to .disconnected; a prompt can only
        // be accepted while the controller is connected, so its absence means
        // the link dropped under the sheet.
        guard let tunnel = devices[prompt.deviceID]?.commandTunnel else {
            pairingPrompt?.status = .failed("controller disconnected")
            return
        }
        pairingPrompt?.status = .inProgress
        do {
            _ = try await NS2Pairing.run(
                deviceID: prompt.deviceID,
                tunnel: tunnel,
                hostAddress: prompt.hostAddress
            )
```

The remainder of the function is unchanged.

- [ ] **Step 3: Build and run the unit suite**

Run: `xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -destination 'platform=macOS' test -only-testing:WaveBirdTests`
Expected: PASS (`NS2PairingVectorTests` still pins the frame bytes; they don't touch `run`).

- [ ] **Step 4: Commit**

```bash
git add WaveBird/Pairing/NS2Pairing.swift WaveBird/Bridge/BridgeCoordinator+Pairing.swift
git commit -m "pairing: send the LTK exchange through CommandTunnel

Byte-identical frames; only serialisation changes, so a late accept
while SDL is initialising can't trip BLETransport's overlap precondition.

Needs hardware: one fresh pair + one repair on any controller."
```

---

### Task 7: Docs — CLAUDE.md

**Files:**
- Modify: `CLAUDE.md:23`, `:64`, and the "Scope" section (`:9-12`)

- [ ] **Step 1: Update the catalog line (line 23)**

Replace `Shipping modes: \`switchPro\`, \`dualShock4\`, \`dualSense\`, \`xboxSeries\`; \`ns2Passthrough\` and \`switch2ProSDL\` are \`#if DEBUG\` only.` with:

`Shipping modes: \`switchPro\`, \`dualShock4\`, \`dualSense\`, \`xboxSeries\`; \`ns2Relay\` is \`#if DEBUG\` only (see "NS2 relay" below).`

- [ ] **Step 2: Update the secondary-inputs gotcha (line 64)**

Replace `Every shipping presentation requires none.` with `Every presentation, including \`ns2Relay\`, requires none — relay must not subscribe 0x09 because SDL's \`HandleStatePacket\` doesn't check the report ID.`

- [ ] **Step 3: Add a relay paragraph**

After the "Rumble" section (before "## Input config"), insert:

```markdown
## NS2 relay (DEBUG-only)

- `ns2Relay` publishes a solo controller under its real VID/PID with the real report set plus a vendor command tunnel (`0x80` out / `0x81` in). SDL's Switch 2 driver, patched with a virtual transport, runs its own init through the tunnel; WaveBird only moves bytes. Contract and rationale: `docs/superpowers/specs/2026-09-10-ns2-relay-design.md`; SDL side: `docs/superpowers/plans/2026-09-10-sdl-virtual-transport.md`.
- `CommandTunnel` (`Bridge/CommandTunnel.swift`) is a per-connection actor that serialises every post-`.ready` `sendAwaitingResponse` — relay commands and the LTK pairing exchange both go through it, which is what keeps `BLETransport`'s one-pending-command precondition safe when CoreHID delivers set-reports concurrently.
- Set-report `data` from CoreHID includes the report ID at index 0 (the `VirtualHIDDevice.SetReportHandler` doc comment is wrong about this; every parser in `HID/` indexes accordingly). Relay rewrites byte 0 to `0x00` for rumble and drops it for tunnel frames.
- Relay descriptors for GC/Joy-Con carry a Generic Desktop / Game Pad outer collection because SDL's only-controllers filter rejects bare vendor-page devices.
- Stays DEBUG-only until a released SDL carries `SDL_HID_API_BUS_VIRTUAL`.
```

- [ ] **Step 4: Fix the `SetReportHandler` doc comment it references**

In `WaveBird/HID/VirtualHIDDevice.swift` lines 8–12, replace `\`data\` is the report payload (excluding the leading ID byte; the parsed ID is passed separately).` with `\`data\` is the on-wire frame including the report ID at index 0 (the parsed ID is also passed separately) — every parser in HID/ indexes from 1.`

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md WaveBird/HID/VirtualHIDDevice.swift
git commit -m "docs: describe the NS2 relay mode and CommandTunnel

Also correct the SetReportHandler comment: CoreHID includes the report
ID byte in the data it hands the handler."
```

---

### Task 8: Hardware validation **[hardware]**

No code. Requires the SDL plan's Tasks 1–2 applied and Dolphin or `testcontroller` built against `install-mac/`. Record results in the commit body of a follow-up `docs:` commit or in the PR description.

- [ ] **Step 1: Pro over relay** — select "NS2 Relay (SDL)" in the Debug build, launch `testcontroller` from the patched SDL build. Expect: device appears as "Nintendo Switch Pro Controller"; sticks follow factory (and user, if set) calibration; gyro/accel move in the sensors view; HD rumble both bands; player LED follows the slot.
- [ ] **Step 2: Report 0x05 keeps flowing after init** — leave the pad idle 30 s, then press a button; expect immediate response (guards the 0x09 rule).
- [ ] **Step 3: GC over relay** — analog L/R reach full pull with correct rest position; single-motor rumble on/off.
- [ ] **Step 4: Joy-Con L and R solo, then both relayed** — SDL combines them into one gamepad; both sticks and both rumble motors work.
- [ ] **Step 5: Init latency** — in WaveBird's stderr log, note the time between a `[hid] setReport … id=0x80` line and the following `0x81` dispatch for each init command once; confirm all are under 1 s.
- [ ] **Step 6: Watchdog** — start rumble in `testcontroller`, then kill it (`kill -9`); the motor must stop within about 1 s.
- [ ] **Step 7: Late pairing accept** — forget the controller, reconnect with relay active, and press Accept on the LTK prompt while `testcontroller` is starting. Expect: no crash (`overlapping sendAwaitingResponse` precondition), pairing completes, SDL init completes.
- [ ] **Step 8: Idle soak** — leave a relayed controller connected in `testcontroller` for >10 minutes without input; it must stay connected (relay is exempt from the idle sweep).
- [ ] **Step 9: GameController claim check** — with relay active, run `Tools/GameControllerProbe.swift` and note whether macOS claims the raw NS2 VID/PID as a `GCController`. Record the answer in the PR; nothing depends on it.

---

## Self-review

**Spec coverage.**
- Identity table → Task 3 (`vendorID`/`productID`/`productName`/`manufacturer`), `hidSerialNumber` scoping is the existing `makeVirtualHID` code (untouched).
- Descriptor table → Task 2 (0x05 in, 0x09 in for Pro, rumble out per product, 0x80/0x81 tunnel on page 0xFF00).
- Input framing + never-subscribe-0x09 → Task 3 (`transformRawReport`, default `requiredSecondaryReportIDs`).
- Rumble relay (byte 0, 42-byte length, cadence cancelled, watchdog stays) → Task 3 + Task 5.
- Command tunnel (trim, byte 2, 0x81 padding, one in flight, 1 s timeout, 0x15 denylist) → Task 3 + Task 1 + Task 5.
- Initialisation ownership → no code; existing `.ready` ordering already puts SDL's init after WaveBird's.
- `NS2RelayOutput` struct → Task 3. Coordinator wiring → Task 5. Pairing through the tunnel → Task 6.
- Catalog + deletions + `resolved(id:)` fallback → Task 4. "The Joy-Con pair never offers relay; a side's relay preference doesn't leak into the pair" → the first draft had no task for this (the pair form path would have handed `JoyConPairProfile` to the relay factory). Fixed as Task 4 Step 3b (`pairExcludedModeIDs` guard in `formJoyConPair` + the picker filter) with `pairPickerHidesRelayProfiles` pinning the filter. The coordinator path itself is `@MainActor` and owns transports, so it isn't unit-tested; Task 8 Step 4 covers it on hardware.
- Tests list → Tasks 1–4.
- Verification / hardware → Task 8.

**Placeholder scan.** No TBD/TODO. Every code step has its code. Task 8 is hardware-only by design and says so.

**Type consistency.**
- `CommandTunnel.send(_:timeout:)` — same in Tasks 1, 5, 6.
- `relayDescriptor` — Tasks 2, 3, 7. `ns2TunnelDescriptorBlock`, `ns2RelayDescriptor(rumbleOutputReportID:)` — Tasks 2, 3 tests.
- `NS2RelayOutput.tunnelResponseReport(_:)` — Tasks 3, 5. `rumbleReportID(forProductID:)` — Task 3.
- `HIDOutputCatalog.pairExcludedModeIDs` / `pairSelectableProfiles(from:)` — Task 4 (coordinator, picker, test).
- `makeSetReportHandler(... tunnel:)` — Task 5 only (pair handler untouched).
- `NS2Pairing.run(deviceID:tunnel:hostAddress:)` — Task 6 only.
- `DeviceRecord.commandTunnel` — Tasks 5, 6.
