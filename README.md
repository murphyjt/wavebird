# WaveBird

A macOS app that bridges Nintendo Switch 2 controllers to a virtual HID gamepad,
so games and other apps can use them as standard controllers.

Switch 2 controllers don't pair via the standard Bluetooth Security Manager
Protocol and don't expose HID over GATT — they speak Nintendo's proprietary
profile over a vendor BLE service. macOS therefore can't pair or use them
natively. WaveBird connects via CoreBluetooth, parses the proprietary report
format into a canonical state, and re-publishes each controller as a virtual
HID gamepad through CoreHID.

## Status

Early. Currently supports:

- **Nintendo GameCube Controller (NSO/NS2)** over Bluetooth LE

Not yet supported: NS2 Pro Controller, Joy-Con (L/R), USB connections.

## Requirements

- macOS 26.2 or newer
- Xcode 26 or newer (Swift 6.2)

## Build

```sh
xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug build
```

Or open `WaveBird.xcodeproj` in Xcode and run.

## Use

1. Launch the app — it begins scanning automatically.
2. Hold the SYNC button on your GameCube Controller until the LEDs flash.
3. WaveBird will discover and connect; the controller appears in the device
   list with a Hz readout once reports are flowing.

The virtual gamepad is visible to apps that use the Game Controller framework
or the WebHID / Gamepad APIs (Chrome / Safari gamepad testers like
[lizardbyte gamepad-tester](https://app.lizardbyte.dev/gamepad-tester/)). Note
that virtual HID devices created via `CoreHID` do **not** show up in
*System Settings → Game Controllers* — that surface is reserved for system
gamepads. This is a macOS limitation, not a bug.

## Credits

- [BlueRetro](https://github.com/darthcloud/BlueRetro) by darthcloud — protocol
  reference for Switch 2 controllers (Apache 2.0).
- [switch2_controller_research](https://github.com/ndeadly/switch2_controller_research)
  by ndeadly — detailed write-ups of the Switch 2 BLE / HID protocol.
- [SDL](https://github.com/libsdl-org/SDL) — `SDL_hidapi_switch2.c` for the
  factory trigger-calibration flash layout; `SDL_hidapi_switch.c` for the
  Switch 1 Pro Controller subcommand handshake the Switch Pro spoof
  emulates (zlib).
- [dekuNukem/Nintendo_Switch_Reverse_Engineering](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering)
  — write-up of the Switch 1 Bluetooth HID protocol (subcommand IDs, report
  0x30 button/stick layout) used by the Switch Pro spoof.

## License

MIT — see [LICENSE](LICENSE).
