# NYXI Hyperion 3 (experimental)

First milestone: BLE connection, buttons, sticks and the existing single-gamepad
L+R merge. The diagnostic build was tested with the user's physical Hyperion 3
pair on 2026-10-23; Nintendo's shared-channel initialization and profiles remain
the default.

## Protocol findings

The separate-console-channel hypothesis is confirmed in
[joycon2android PR #26](https://github.com/JoeGeC/joycon2android/pull/26),
its [protocol documentation](https://github.com/JoeGeC/joycon2android/blob/b70046d60f43ce0df86cedf16cf7837ac5e5cba6/docs/protocol.md#console-protocol-controllers),
and `ConsoleChannel`, `ConsoleCommands`, `ConsoleSession`, `ConsoleTransport`, and
`ConsolePacketParser` under that revision's
[`connection/console`](https://github.com/JoeGeC/joycon2android/tree/b70046d60f43ce0df86cedf16cf7837ac5e5cba6/feature/connection/data/src/main/kotlin/com/joegec/joycon2android/connection/console).
WaveBird baseline: `b04a072f1b17df58965efb14a066873a0b48da2a`.

| Purpose | L | R |
| --- | --- | --- |
| Command (without response) | `ce49a830-dced-48ae-931e-c8cf88aadbea` | `65a724b3-f1e7-4a61-8078-a342376b27ff` |
| Input notification | `cc1bbbb5-7354-4d32-a716-a81cb241a32a` | `d5a9e01e-2ffc-4cca-b20c-8b67142bf442` |
| Extended response | `63a3810f-aec7-474b-9010-3d52403cb996` | `640ca58e-0e88-410c-a7f3-426faf2b690b` |

Session start is `01 00` to `00c5af5d-1964-4e30-8f51-1956f96bd282`.
This characteristic belongs to the **separate** service ending `d280`, not the
input service ending `7fd0`; both services must be discovered. See the primary
[GATT table](https://github.com/ndeadly/switch2_controller_research/blob/master/bluetooth_interface.md#gatt-attributes).
Commands have 17 zero bytes before the normal eight-byte Nintendo command header.
The input's report-rate descriptor `679d5510-5a24-4dee-9557-95df80486ecb` receives
`85 00` before subscribing. Common responses use `c765a961-…-836a`.

The common channel is tried first. For Joy-Cons only, two unanswered initial
commands stop further common probing. No common input within 1.5 seconds after
the input subscription switches to the console sequence. A late common input
switches back. Pro/GameCube never enter console fallback. Pending command
timeouts have request tokens, so an old timeout cannot expire a newer request;
SPI replies also match the requested address. Initialization checks connection
generations across suspension points to avoid writes from a disconnected session.

Console input: counter at 0, power at 1, LE button bits at 2–3, marker `07` at 4,
packed 12-bit stick at 5–7. `NS2Console.sharedReport` translates just buttons and
the correct side's stick to WaveBird's existing Report 0x05 layout. In WaveBird,
the first button byte is **4**, not Android's uint32 offset 3. Existing profiles
and `JoyConPairProfile.merge` then produce the normal HID output.

Console mode uses the peripheral UUID for persistent identity (clones can repeat
Nintendo factory serials), skips Nintendo factory calibration and LTK prompts,
and does not write pairing command `0x15`. Hold SYNC for initial testing.
Sticks use WaveBird's existing centered 12-bit fallback; travel and center need
hardware checks. Motion, battery display and gameplay rumble are outside this
milestone; console-mode vibration writes are suppressed. The documented
connection vibration sample is retained as part of the startup sequence.

Android's pairing-broadcast suppression and pending L2CAP channel fix depend on
AOSP internals. They have not been transplanted to macOS. CoreBluetooth's behavior when NYXI requests SMP security was initially an open
hardware question. In the first macOS run both halves remained connected past
four minutes without either workaround. This is evidence for this Mac/firmware
combination, not a guarantee for every controller firmware or macOS release.

## Build and diagnostics

Full WaveBird uses `com.apple.developer.hid.virtual.device`. Xcode requires a
matching macOS provisioning profile with HID Virtual Device enabled. A full
Xcode installation and an ordinary development certificate alone are insufficient.
Keep the shipping entitlements; select an approved team/profile in Xcode when
building the full bridge. A compile-only verification is possible with
`CODE_SIGNING_ALLOWED=NO`, but that does not grant permission to create a gamepad.

To test BLE and physical input without that managed entitlement:

```sh
bash Tools/nyxi-diagnostics.sh
```

This builds an ad-hoc signed, separately identified `WaveBirdNYXIDiagnostics.app`
using the same production transport, decoder and pair merge. It shows live input
and **does not create a system gamepad**. It does not replace the installed
WaveBird or change its stored preferences. Use `--build-only` to skip launch.
Quit the installed WaveBird before testing so two apps do not initialize the
same controllers. Grant Bluetooth access if macOS asks.

Logs: `build/nyxi-diagnostics.log`; build log: `build/diagnostics-build.log`.
`[nyxi][UUID]` entries include discovery, GATT properties, notify/descriptor
results, channel selection, raw first 16 bytes and decoded input, five-second
health summaries, report counts and disconnect errors. `[nyxi] merged` shows
the pair state. Debug input logs are rate-limited for sticks; button changes
are always logged. Initialization command responses retain WaveBird's existing
`[ble]` diagnostics in the full app.

## Validation

```sh
xcodebuild -project WaveBird.xcodeproj -scheme WaveBird \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  test -only-testing:WaveBirdTests
```

`NS2ConsoleTests` uses the published NYXI resting-right capture, verifies every
button on both sides, stick rails, L+R merging and missing-side neutrality,
truncated/sliced data, command framing and prefixed/stale SPI replies. The
existing Nintendo stick, output, mapping and pairing-vector suites also run.
These tests cannot establish macOS BLE or physical input behavior.

Hardware checklist:

1. Hold SYNC on L, then R. Confirm console mode and continuing report counts.
2. Keep both connected for at least 60 seconds; check for a security dialog,
   dropped link or frozen input, especially around 30–35 seconds.
3. Press/release each face button, D-pad direction, shoulder, trigger, stick
   click, +/−, Home/Capture/C and accessible SL/SR separately.
4. Move each stick through full travel and release; confirm the other stick
   stays neutral and the merged display retains both sides simultaneously.
5. Power off either side. Its merged buttons/stick must clear. Hold SYNC to
   reconnect and repeat. Test reverse connection order.
6. With an entitled full build, select one output profile for the L+R pair and
   check exactly one gamepad in `Tools/GameControllerProbe.swift` or a game.
7. Retest genuine Nintendo Joy-Con 2 on the common channel, including stored
   output preferences, pairing/reconnection, and one merged gamepad.

## Verified on this Mac — 2026-10-23

- macOS 27.0 (`26A428`), Xcode 27.1 (`27A9275`), Apple silicon.
- Main app compile-only build: succeeded. Full app signing: blocked by missing
  provisioning profile with HID Virtual Device. No system-gamepad claim is made.
- Separate diagnostic app: built with ad-hoc signing and Bluetooth entitlement;
  launched and received both physical halves through the console fallback.
- Unit suite: **98 passed**, including eight console tests and existing Nintendo
  parsing/output/mapping/pairing tests.
- Both sides delivered over 17,000 reports in the initial session, approximately
  67 reports/second for over four minutes. Notification and report-rate descriptor
  callbacks reported no GATT errors; no spontaneous 30–35-second disconnect.
- Log observed A/B/X/Y, D-pad, L/R/ZL/ZR, LS/RS, independent sticks and simultaneous
  L+R state. The user additionally confirmed all requested physical buttons match
  the display and powering off / reconnecting works.
- Physical Nintendo regression and a real single virtual gamepad remain to be
  tested with the entitled full build. The diagnostic app verifies the shared
  merge function but does not publish HID output.

Local evidence is retained in `build/nyxi-diagnostics.log`, `build/tests.log`, and
`build/diagnostics-build.log` (ignored by Git). The test suite also contains the
published hardware capture so decoder verification is reproducible.
