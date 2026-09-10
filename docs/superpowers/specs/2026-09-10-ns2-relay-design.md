# NS2 relay mode and the SDL virtual transport

**Status:** design, approved in conversation 2026-09-10. Implementation not started.

## Problem

SDL3's `SDL_hidapi_switch2.c` is the only consumer that understands a Switch 2
controller natively (analog GC triggers, real calibration, gyro, HD rumble,
player LED). It has one working transport: USB, where commands and responses
travel over libusb bulk endpoints and state/rumble travel over the HID
interface. Its Bluetooth branch is a bare "not supported" error, and no OS
will ever expose an NS2 over BLE as a HID device because the controller speaks
custom GATT with no HID-over-GATT profile.

WaveBird owns the BLE link. Today it can only hand SDL a spoofed third-party
pad (Switch Pro, DualSense, ...), losing the Switch 2 driver's features. A
CoreHID virtual device presents `Transport = Virtual`, which stock SDL treats
as USB, so the driver tries libusb and fails.

## Decision

Add a **relay** output mode in WaveBird and a **virtual transport** in SDL's
Switch 2 driver. The bridge is a dumb transport: SDL owns the controller
protocol end to end, WaveBird moves bytes between HID reports and GATT
characteristics. This was chosen over an "input-only, pre-calibrated" contract
because the relay keeps the SDL driver the single protocol implementation, has
no faked calibration, and mirrors how the driver already splits USB from
Bluetooth.

Relay replaces the two DEBUG-only precursors, `ns2Passthrough` and
`switch2ProSDL`. It is **DEBUG-only** until a released SDL carries the virtual
transport; a stock SDL app would see a raw NS2 it cannot initialise, which is
worse than no device.

## Scope

In scope:

- One catalog entry `ns2Relay` ("NS2 Relay (SDL)"), `#if DEBUG`.
- Solo controllers: NS2 Pro, NSO GameCube, Joy-Con L, Joy-Con R. SDL combines
  two relayed Joy-Cons itself, so the merged WaveBird pair never offers relay
  and `JoyConPairProfile` is untouched.
- Deleting `NS2PassthroughOutput` (in `HID/HIDOutputProfile.swift`) and
  `HID/Switch2ProSDLOutputProfile.swift`.
- The SDL patch: bus-type plumbing (macOS + Linux hidapi, public enum, joystick
  device flag) and the Switch 2 driver's virtual transport.

Out of scope:

- Windows. Its hidapi has no virtual-bus signal; nothing to gate on.
- A DriverKit extension. Orthogonal; the relay works on CoreHID.
- Any change to how WaveBird initialises, pairs, or reconnects controllers.
- USB transport in WaveBird.

## The HID contract

Both sides implement this. It is reproduced as the header comment of the SDL
virtual transport so a bridge on another OS (e.g. Linux uhid) can follow it.

### Identity

| Field | Value |
|---|---|
| VID / PID | the controller's real NS2 identity (`0x057E` / `0x2069` Pro, `0x2073` GC, `0x2066` L, `0x2067` R) |
| Product / Manufacturer | real strings |
| Transport | `Virtual` (what CoreHID publishes; SDL maps it to `SDL_HID_API_BUS_VIRTUAL`) |
| HID serial | WaveBird's existing `hidSerialNumber(deviceSerial:modeID:)` scoping |

### Descriptor

The real NS2 USB HID report set plus two vendor tunnel reports:

| Report | Dir | Size (payload) | Meaning |
|---|---|---|---|
| `0x05` | In | 63 | controller state, BLE Report 0x05 payload verbatim |
| `0x09` (Pro only) | In | 63 | declared for fidelity, **never emitted** |
| `0x01` / `0x02` / `0x03` | Out | 63 | native rumble packet for Joy-Con / Pro / GC |
| `0x80` | Out | 64 | tunnel: command request frame |
| `0x81` | In | 80 | tunnel: command response frame |

Tunnel reports live in the vendor usage page `0xFF00`, the same page the
existing `ns2VendorDescriptor` uses. Pro reuses `usbPassthroughDescriptor` plus
the tunnel block. GC and Joy-Con currently declare an input-only vendor
descriptor; relay adds their rumble output report (`0x03` / `0x01`) and the
tunnel block.

### Input

Every unprefixed BLE notification on the shared input handle `0x000A` is
dispatched as report `0x05`: `[0x05] + payload`, zero-padded to 63 bytes when
BLE truncates. This is byte-identical to the real USB HID input, which is why
SDL's state parser needs no change.

The relay **must not** subscribe Pro's secondary handle `0x000E` (Report
0x09): doing so suppresses 0x05 (see CLAUDE.md), and SDL's
`HandleStatePacket` does not check the report ID, so a 0x09 frame would parse
as garbage state. `requiredSecondaryReportIDs` is empty.

### Rumble

Host output report `0x01` / `0x02` / `0x03` is written to the vibration
characteristic verbatim with byte 0 rewritten to `0x00` (BLE framing byte,
not a HID ID). SDL builds these packets in exactly the layout WaveBird's own
encoders emit (`0x50 | tid` state byte, LRA ops), so no re-encoding. The
existing 42-byte Pro relay in passthrough generalises to all three IDs. The
relayed length for each ID equals the byte count that profile's `encodeRumble`
produces today (42 for Pro and GC), so the BLE write is the same size the
controller already accepts from WaveBird.

Host-driven cadence: any in-flight `RumbleRefreshBox` loop is cancelled, as
passthrough does today. The 1 s stop watchdog stays.

### Command tunnel

- SDL writes output report `0x80` carrying a command frame exactly as it would
  send over bulk: `[cmd, 0x91, transport, subcmd, 0x00, len, 0x00, 0x00,
  payload...]`, padded to 64 bytes.
- The bridge takes the first `8 + len` bytes (SDL itself sends exactly
  `init_sequence[i][5] + 8` bytes over bulk; the rest of the report is zero
  padding), rewrites byte 2 from `0x00` (USB) to `0x01` (Bluetooth), and sends
  it to the command characteristic `0x0014` awaiting a response on `0x001A`.
  `0x01` is the value every hardware-validated WaveBird frame uses; we do not
  test whether the controller accepts `0x00` over BLE.
- The response frame is dispatched as input report `0x81`: `[0x81] + frame`,
  zero-padded to 80 bytes. Responses are not modified (SDL never reads byte 2).
- **One command in flight per device.** The bridge serialises tunnel commands.
- **Timeouts.** Bridge waits 1 s for a response (WaveBird's own commands use
  500 ms; BLE acks can exceed 300 ms). If nothing arrives, nothing is sent; SDL's
  own deadline (2 s) fires.
- **Denylist.** Command ID `0x15` (LTK pairing) is dropped without a response.
  SDL never sends it; the relay must not let a host rewrite the pairing key.

### Initialisation ownership

WaveBird still runs its own init before `.ready` (handshake, flash reads,
LED, feature mask, deferred input subscription). Pairing, the serial-keyed
records, and the UI depend on it. The VHID is created at `.ready`, so SDL's
init always runs after WaveBird's. SDL's commands are relayed verbatim and its
settings win; both sides send the same feature mask (`0x27`), so there is no
observable conflict. This is deliberately **not** a "bridge skips init" mode.

## WaveBird design

### `NS2RelayOutput` (`HID/NS2RelayOutputProfile.swift`)

Struct conforming to `HIDOutputProfile` and `HIDOutputSession`, stateless,
`makeSession` returns `self`. Takes the input `ControllerProfile` for
VID/PID/name/descriptor, like passthrough did.

- `descriptor`: `profile.vendorPassthroughDescriptor` (updated per the
  Descriptor section).
- `transformRawReport(reportID:data:)`: `reportID == nil` → `[0x05] + payload`
  padded to 63; anything else → `nil` (and nothing else is subscribed anyway).
- `rawVibrationPayload(type:id:data:)`: `.output` with id `0x01`/`0x02`/`0x03`
  matching the profile's product → verbatim copy with byte 0 = `0x00`.
- `relayCommand(type:id:data:) -> Data?` (new `HIDOutputSession` hook,
  default `nil`): `.output` with id `0x80` → the trimmed frame with byte 2
  rewritten, or `nil` for `0x15`.
- `buildReport` returns empty `Data` (never reached; `transformRawReport`
  short-circuits every report).

### Coordinator wiring (`Bridge/BridgeCoordinator+OutputMode.swift`)

In `makeSetReportHandler`, before the rumble branches:

```
if let frame = session.relayCommand(type: type, id: id, data: data) {
    await tunnel.send(frame) { response in
        try? await device.dispatchInputReport(data: [0x81] + response padded to 80)
    }
    return
}
```

`tunnel` is a `CommandTunnel` actor created per relay device (stored on
`DeviceRecord`, torn down with the VHID). It serialises calls to
`transport.sendAwaitingResponse(_:to:timeout: .seconds(1))` so
`BLETransport`'s no-overlap precondition can never trip if CoreHID delivers
set-reports concurrently.

Known interaction: the pairing exchange (`+Pairing.swift`) also uses
`sendAwaitingResponse` and can run after `.ready` if the user accepts the
prompt late. While a relay session is active, the pairing exchange routes its
awaiting sends through the same `CommandTunnel`. No other post-`.ready`
awaiting sends exist (test rumble uses `sendVibration`).

### Catalog and cleanup

- `HIDOutputCatalog.default`: remove `ns2Passthrough` and `switch2ProSDL`,
  add `Entry(id: "ns2Relay", displayName: "NS2 Relay (SDL)") { NS2RelayOutput(profile: $0) }`
  under `#if DEBUG`.
- Persisted `preferredOutputModeID` values naming the removed modes resolve
  through the existing `resolved(id:)` fallback. No migration.
- The Joy-Con pair picker (`JoyConPartnerSheet` / pair-form path) never
  offers `ns2Relay`; if a side's per-serial preference is relay when a pair
  forms, the pair uses its own mode as today.
- `ProControllerProfile.secondaryInputs` stays (it is the catalog of channels);
  nothing subscribes it after passthrough is gone.

### Tests (`WaveBirdTests`)

Golden-byte tests, Swift Testing:

- Descriptor per profile contains the tunnel block exactly once and the
  expected rumble output ID.
- `relayCommand`: SDL's "set feature output bit mask" frame in → byte 2 is
  `0x01`, everything else identical, length trimmed; `0x15` frame → `nil`;
  a `0x02` (flash read) frame preserves the address bytes.
- `rawVibrationPayload`: SDL's GC / Pro / Joy-Con rumble reports → byte 0 is
  `0x00`, remainder identical, length matches the profile encoder's output.
- `transformRawReport`: 62-byte BLE frame → 64 bytes `[0x05] + payload + 0`.

## SDL design

Branch off current `main` (`04b2fb804` at design time). The earlier local
`is_virtual` patch is stashed (`wavebird is_virtual patch (pre-relay
design)`) and superseded; do not reapply it.

### Bus type plumbing

- `include/SDL3/SDL_hidapi.h`: `SDL_HID_API_BUS_VIRTUAL = 0x05` with a doc
  comment ("a software bridge publishing a virtual HID device; the bridge owns
  the physical link").
- `src/hidapi/hidapi/hidapi.h`: `HID_API_BUS_VIRTUAL = 0x05`.
- `src/hidapi/mac/hid.c`: in both transport switches, map
  `kIOHIDTransportVirtualValue` (`"Virtual"`) to `HID_API_BUS_VIRTUAL`.
- `src/hidapi/linux/hid.c`: admit `BUS_VIRTUAL` (`0x06` from `linux/input.h`)
  in the filter switch and map it. Today it is filtered out entirely, so a uhid
  bridge is invisible to SDL.
- `src/joystick/hidapi/SDL_hidapijoystick_c.h` / `.c`: `bool is_virtual`, set
  from `bus_type == SDL_HID_API_BUS_VIRTUAL` next to `is_bluetooth`.

### Switch 2 driver (`src/joystick/hidapi/SDL_hidapi_switch2.c`)

- Split `HIDAPI_DriverSwitch2_InitUSB` into `InitUSBTransport` (libusb init,
  handle, endpoints, claim) and `InitController` (flash reads + init sequence).
  USB calls both; a new `InitVirtual` calls only `InitController`.
- Rename `SendBulkData` → `SendCommand`, `RecvBulkData` → `RecvResponse`.
  - USB: unchanged bodies.
  - Virtual `SendCommand`: copy into a 64-byte buffer with `[0] = 0x80`,
    `SDL_hid_write`. Returns `size` on success.
  - Virtual `RecvResponse`: loop `SDL_hid_read_timeout(dev, buf, 81, remaining)`
    until `buf[0] == 0x81` or 2000 ms elapse; copy `buf + 1` into `data`
    (up to `size`) and return the count; other reports (state 0x05) are
    dropped while waiting. Returns 0 on timeout, matching the bulk path's
    "short read" semantics so callers that ignore the reply keep working.
- `InitDevice`: `if (is_virtual) InitVirtual else if (is_bluetooth) ... else InitUSB`.
- `UpdateDevice`: on virtual, `continue` on `data[0] == 0x81` so a late reply
  is never parsed as state. USB path untouched (no report-ID check added
  there; that would be a behaviour change outside this work).
- `FreeDevice`: virtual has nothing to release; the existing `libusb` guards
  already handle that.
- Rumble (`UpdateRumble` → `SDL_HIDAPI_SendRumbleAndUnlock` → `hid_write`),
  `UpdateSlotLED`, and `SetJoystickSensorsEnabled` need no change: they go
  through `SendCommand`/`RecvResponse` or `hid_write` already.
- Header comment on `InitVirtual` carries the HID contract verbatim.

### Upstream plan

1. Open an SDL issue describing the contract and naming WaveBird as the
   shipping bridge. Ask specifically about the public enum addition.
2. PR after the issue has a response, with the hardware results below.
3. Until the change is in a released SDL, WaveBird keeps `ns2Relay` DEBUG-only.
   Dolphin for local testing is built against the patched SDL (existing
   `install-mac/` flow in the SDL clone).

## Verification

Automated: `xcodebuild ... test -only-testing:WaveBirdTests` for the golden
tests; SDL builds with `-DSDL_HIDAPI_JOYSTICK=ON` and `test/testcontroller`
runs.

Hardware pass (required; none of this is verifiable without controllers):

- Init completes within SDL's 2 s deadline on Pro and GC; log the per-command
  latency once to size the timeouts.
- Report 0x05 keeps flowing after init (regression guard for the 0x09 rule).
- GC: analog L/R with real trigger zeros; single-motor rumble on/off.
- Pro: sticks against factory calibration and, if set, user calibration;
  gyro/accel via `testcontroller` sensors; HD rumble both bands.
- Joy-Con L and R solo, then both relayed and combined by SDL.
- Player LED follows SDL's player index.
- Late pairing accept while SDL is initialising does not trip the
  `sendAwaitingResponse` precondition.
- Whether macOS GameController claims a raw NS2 VID/PID on this OS build
  (`GCController.supportsHIDDevice`). If it does, note it; nothing in this
  design depends on the answer, but it changes what other apps see.
