# WaveBird

A macOS app that bridges Nintendo Switch 2 controllers to a virtual HID gamepad,
so games and other apps can use them as standard controllers. Tested with Apple
Game Controller framework apps, SDL-based apps (Steam, Dolphin), and the web
Gamepad API.

Switch 2 controllers don't pair via the standard Bluetooth Security Manager
Protocol and don't expose HID over GATT — they speak Nintendo's proprietary
profile over a vendor BLE service. macOS therefore can't pair or use them
natively. WaveBird connects via CoreBluetooth, parses the proprietary report
format into a canonical state, and re-publishes each controller as a virtual
HID gamepad through CoreHID.

## Status

Early. Currently supports:

- **Nintendo Switch 2 GameCube Controller (NSO)** over Bluetooth LE —
  analog sticks, all face/shoulder buttons, D-pad, Rumble and Motion
- **Nintendo Switch 2 Pro Controller** over Bluetooth LE — analog sticks,
  all buttons including Home and Capture, Rumble and Motion

Not yet supported: Joy-Con 2, Charging Grip and USB connections.

## Output profiles

Each connected controller can present as a different virtual gamepad. Use the
per-device drop-down in the app to switch:

| Profile | Rumble | Motion | Notes |
|---|---|---|---|
| **Native (Switch 2)** | [ ] | [ ] | Work in progress |
| **Switch Pro Controller** | [x] | [x] | Recommended |
| **DualShock 4** | [ ] | [ ] | Work in progress |
| **DualSense** | [ ] | [ ] | Work in progress |
| **Xbox Wireless Controller** | [x] | [ ] | Recommended; missing Home button |

The selection persists per-device across reconnects.

Select output profiles (Switch Pro, DualShock 4, DualSense, Xbox) appear in
*System Settings → Game Controllers*, where they can be remapped and customized.
The Native profile does not — virtual HID devices with custom VID/PID don't
surface there. This is a macOS limitation.

## Requirements

- macOS 26.0 or newer
- Xcode 26 or newer (Swift 6.2)

## Build

```sh
xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug build
```

Or open `WaveBird.xcodeproj` in Xcode and run.

## Permissions

WaveBird needs two privacy permissions the first time it runs. macOS may prompt
for them automatically, or you can grant them manually:

**System Settings → Privacy & Security → Accessibility** — required to publish
a virtual HID gamepad.

**System Settings → Privacy & Security → Bluetooth** — required to scan for and
connect to controllers.

If a permission prompt appears, click **Allow**. If WaveBird is listed but
unchecked, check it and relaunch.

> **Note:** If you granted permissions for a previous version and the virtual
> gamepad stopped appearing after updating, open **Privacy & Security →
> Accessibility**, remove WaveBird, and re-add it — macOS sometimes doesn't
> re-validate an existing entry after a binary update.

## Use

1. Launch the app — it begins scanning automatically.
2. Hold the SYNC button on your controller until the LEDs flash.
3. WaveBird discovers and connects; the controller appears in the device list
   with a live Hz readout once reports are flowing.
4. Click the controller card to make changes to controller settings
5. Use the drop-down to choose which virtual gamepad it presents as (Switch Pro, DualSense, Xbox, etc.).

The virtual gamepad is visible to apps that use the Game Controller framework
or the WebHID / Gamepad APIs (Chrome / Safari gamepad testers like
[lizardbyte gamepad-tester](https://app.lizardbyte.dev/gamepad-tester/)).

## Credits

- [BlueRetro](https://github.com/darthcloud/BlueRetro) by darthcloud — protocol
  reference for Switch 2 controllers (Apache 2.0).
- [switch2_controller_research](https://github.com/ndeadly/switch2_controller_research)
  by ndeadly — detailed write-ups of the Switch 2 BLE / HID protocol.
- [SDL](https://github.com/libsdl-org/SDL) — `SDL_hidapi_switch2.c` for the
  factory trigger-calibration flash layout and the NS2 LRA `EncodeHDRumble`
  bit packing; `SDL_hidapi_switch.c` for the Switch 1 Pro Controller
  subcommand handshake the Switch Pro spoof emulates, and the NS1 HD Rumble
  amplitude table we invert to decode the spoof's incoming rumble (zlib).
- [dekuNukem/Nintendo_Switch_Reverse_Engineering](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering)
  — write-up of the Switch 1 Bluetooth HID protocol (subcommand IDs, report
  0x30 button/stick layout) used by the Switch Pro spoof, and the
  `rumble_data_table.md` amplitude curve we use to decode NS1 HD Rumble
  bytes back into 16-bit amplitudes before re-encoding for NS2 LRA.

## License

MIT — see [LICENSE](LICENSE).
