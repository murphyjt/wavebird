# Xbox Wireless Controller — how it works

Reference for `XboxSeriesOutputProfile.swift`.

One profile (`XboxSeriesOutput`) serves **every** consumer from a single virtual
device: GameController, the web Gamepad API, and Steam read report `0x01`; SDL
HIDAPI apps (Dolphin) read the GIP `0x20` input the same device also streams.

## Descriptor: real BLE dump + appended GIP vendor reports

`descriptorBytes` starts as the **byte-for-byte report descriptor of a real Xbox
Series X over BLE**, dumped via IOKit (`kIOHIDReportDescriptorKey`, 2026-05-31,
283 bytes). VID `0x045E` / PID `0x0B13` (the BLE Series X PID) — Apple's
`XboxOneHIDServicePlugin` binds it as a `GCController` immediately, no GIP
handshake. We then **append a vendor block** declaring two extra input reports so
SDL/HIDAPI consumers get input from the same device.

| Report ID | Dir | Page | Contents |
|---|---|---|---|
| `0x01` | Input | Generic Desktop | sticks, triggers, hat, 15 buttons, Share |
| `0x03` | Output | PID | rumble (Physical Interface) |
| `0x07` | Input | Vendor `0xFF00` | GIP virtual-key (Guide) — for SDL |
| `0x20` | Input | Vendor `0xFF00` | `GIP_CMD_INPUT` gamepad state — for SDL |

`0x01`/`0x03` are the real Series X's only reports; `0x07`/`0x20` are our
additions. GameController ignores the vendor usage page, so the Apple side still
sees just `0x01`+`0x03`. macOS only delivers an input report ID to HIDAPI clients
if it's **declared**, so `0x20`/`0x07` must be in the descriptor even though
Apple's path ignores them (dispatching an undeclared input ID succeeds silently
but never reaches SDL).

## Report `0x01` wire layout (17 bytes incl. ID)

```
0      report ID 0x01
1..2   LX  uint16 LE (byte 1 has bit 7 forced clear — see "SDL crash" below)
3..4   LY  uint16 LE (high = up; we send high for physical up, no inversion)
5..6   Z   = right stick X
7..8   Rz  = right stick Y
9..10  Brake (LT)        Simulation page, 10-bit LE in bits 0..9, bits 10..15 pad
11..12 Accelerator (RT)  10-bit LE
13     hat low nibble (1=N,2=NE,…8=NW,0=neutral), high nibble pad
14     buttons 1..8:  A=bit0 B=bit1 (bit2 rsvd) X=bit3 Y=bit4 (bit5 rsvd) LB=bit6 RB=bit7
15     buttons 9..15: (bits0,1 rsvd) View=bit2 Menu=bit3 Guide=bit4 L3=bit5 R3=bit6, bit7 pad
16     Share/Capture (Consumer Record 0x0B2) bit0, bits1..7 pad
```

The button bit positions are the real Series X's 15-button HID array (buttons 3,
6, 9, 10 are reserved/unused). Apple parses by HID **usage**, so these land on the
correct `GCExtendedGamepad` / `GCXboxGamepad` controls.

### Button mapping (NS2 → Xbox)

Face buttons cross Nintendo↔Xbox positions: `.b`→A(south), `.a`→B(east),
`.y`→X(west), `.x`→Y(north). Center: `.minus`→View, `.plus`/`.start`→Menu,
`.home`→Guide (button 13), `.capture`→Share (Consumer Record). LB/RB from
shoulders, L3/R3 from stick clicks, triggers from the analog shoulders.

The controller's physical **Home** button is the NS2 input (`.home`); on the Xbox
side it is the **Guide** button. "Guide" is the name everywhere on the Xbox side
(SDL `SDL_GAMEPAD_BUTTON_GUIDE`, the HID descriptor, XInput); "Home" only names
the Nintendo input.

## Serving SDL/Dolphin from the same device

SDL HIDAPI apps (Dolphin) speak GIP and read the vendor `0x20` input, not the
Generic-Desktop `0x01`. `buildSecondaryReports` streams, alongside every `0x01`:

- **`0x20` `GIP_CMD_INPUT`** every frame — the gamepad state in GIP layout. SDL's
  `GIP_HandleGamepadReport` byte offsets match our payload exactly. SDL adds the
  joystick via faked metadata (no device Hello needed), so just streaming `0x20`
  is enough.
- **`0x07` GIP virtual-key (Guide)** only on Home press/release edges (a stateful
  `XboxSeriesSession` actor tracks `lastHome`; streaming an internal packet every
  frame would be noise). Frame is `[0x07, 0x20, 0x00, 0x02, state, 0x5B]` — SDL's
  `GIP_HandleCommandGuideButtonStatus` only registers Guide when the payload's 2nd
  byte is `VK_LWIN` (`0x5B`) and reads the pressed bit from byte 0.

GameController claiming the device does **not** block HIDAPI reads (the Switch Pro
spoof proves it), so one descriptor serves both.

### SDL crash: bit 7 of report `0x01` byte 1

SDL's modern GIP driver (`SDL_hidapi_gip.c`) reads **every** input report off the
device, including our `0x01`, and parses byte 1 as a GIP "flags" field. On the
real Series X, byte 1 is the LX low byte; when it sets the `FRAGMENT` bit (`0x80`)
SDL walks a fragment-reassembly path and NULL-derefs → Dolphin SIGSEGV. We can't
shift the layout to dodge it — Apple's plugin reads PID `0x0B13` by **hardcoded
byte offsets** (a leading pad byte mapped X→Guide). So `buildReport` just clears
bit 7 of byte 1: SDL's `FRAGMENT` bit is never set (it discards our `0x01` as an
unknown GIP message), the layout stays byte-aligned for Apple, and the cost is
≤0.2% of LX travel. The other flag bits are inert (SYSTEM hits a no-op stub, ACME
never acks because `0x01` returns false). See the `reference_xbox_sdl_gip_crash`
memory.

### Advanced toggles

Per-controller (`XboxOutputSettings`, persisted by serial; UI in the detail
sheet's General tab, Xbox mode only):

- **Send SDL/Dolphin input reports** (`sendGIPReports`) — master switch for the
  `0x20`/`0x07` stream. Off → only `0x01` goes out.
- **Send Guide button to SDL/Dolphin** (`sendGuideToSDL`) — gates `0x07`.
- **Send Guide button to macOS** (`sendGuideToSystem`) — masks `.home` from the
  state fed to `buildReport`, dropping report `0x01`'s Guide bit so Steam /
  browsers / the system overlay stop seeing it.

Gating lives in the coordinator's dispatch task (sampled off-main), not the
session, matching how axis/rumble settings flow.

## System buttons: Guide vs Share (Apple side)

- **Share/Capture is app-readable.** A real Series X exposes it as
  `GCXboxGamepad.buttonShare` (and via `physicalInputProfile`), *because* its
  Consumer Record usage rides report `0x01`. Verified against real hardware —
  `Tools/GameControllerProbe.swift` prints `Share` for both a real pad and ours.
- **Guide is system-reserved on the GameController path.** Via report `0x01` it's
  recognized (Controller Shortcuts fire, Steam Big Picture opens) but never
  delivered to apps as a readable `GCController` element — `buttonHome` doesn't
  fire. True for a real Series X too, so it's Apple reserving the button, not a
  spoof defect. (SDL/Dolphin instead get Guide explicitly via the `0x07` GIP
  virtual-key above.)

## Rumble — two Set Report paths

`parseRumble` handles both:

- **Report `0x03`** — GameController.haptics / the web Gamepad API drive the PID
  Physical Interface block in the descriptor:
  `[id, enable(4-bit mask), LT, RT, L, R, duration, delay, loop]`.
- **Report `0x09`** — SDL's Xbox HIDAPI driver (Steam, Dolphin, …) sends GIP
  rumble. The descriptor does **not** declare `0x09`, but CoreHID delivers the Set
  Report anyway (it's host→device; only *input* report IDs are filtered by the
  descriptor), so we parse it with no declaration:
  `[id, 0,0,0x09,0,0x0F, LT, RT, L, R, dur, delay, loop]`.

Magnitudes are 0..100 percent, rescaled to 0..65535 for the NS2 LRA encoder. NS2
Pro has no trigger motors, so trigger magnitudes fold into the main motor via
`max`. `refreshInterval` is 80 ms: Xbox hosts send a start frame and a stop frame
~1 s apart, but the NS2 motor times out after ~300 ms, so the coordinator re-sends
to keep it alive between host frames.
