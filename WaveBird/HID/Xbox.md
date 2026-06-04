# Xbox Wireless Controller — how it works

Reference for `XboxSeriesOutputProfile.swift`.

## Faithful BLE descriptor

`descriptorBytes` is **byte-for-byte the report descriptor of a real Xbox Series
X over BLE**, dumped from a connected controller via IOKit
(`kIOHIDReportDescriptorKey`, 2026-05-31) and verified equal (283 bytes). VID
`0x045E` / PID `0x0B13` (the BLE Series X PID) — Apple's `XboxOneHIDServicePlugin`
binds it as a `GCController` immediately, no GIP handshake.

The real descriptor has exactly **two reports**:

| Report ID | Dir | Contents |
|---|---|---|
| `0x01` | Input | sticks, triggers, hat, 15 buttons, Share |
| `0x03` | Output | PID rumble (Physical Interface) |

There is **no** separate Guide report, no battery report, and no vendor reports.
Guide is just one of the 15 buttons; Share is a Consumer Record usage inside
report `0x01`.

## Scope

This profile (`XboxSeriesOutput`) targets faithful **BLE / GameController**
behaviour and serves GameController, the web Gamepad API, and Steam (via MFi).
SDL HIDAPI-only apps (Dolphin) need GIP `0x20` frames it doesn't send, so they use
the separate `XboxSeriesSDLOutput` profile — see "Two Xbox profiles" below.

## Report `0x01` wire layout (17 bytes incl. ID)

```
0      report ID 0x01
1..2   LX  uint16 LE
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

## System buttons: Guide vs Share

- **Share/Capture is app-readable.** A real Series X exposes it as
  `GCXboxGamepad.buttonShare` (and via `physicalInputProfile`), *because* its
  Consumer Record usage rides report `0x01`. Verified against real hardware —
  `Tools/GameControllerProbe.swift` prints `Share` for both a real pad and ours.
- **Guide/Home is system-reserved.** Recognized (Controller Shortcuts fire, Steam
  Big Picture opens) but never delivered to apps as a readable element —
  `buttonHome` doesn't fire and it's absent from the input profile. This is true
  for a real Series X too (its Home doesn't print in the probe), so it's Apple
  reserving the Xbox Home button, not a spoof defect.

## Rumble — two Set Report paths

`parseRumble` handles both:

- **Report `0x03`** — GameController.haptics / the web Gamepad API drive the PID
  Physical Interface block in the descriptor:
  `[id, enable(4-bit mask), LT, RT, L, R, duration, delay, loop]`.
- **Report `0x09`** — SDL's Xbox HIDAPI driver (Steam, Dolphin, …) sends GIP
  rumble. The faithful descriptor does **not** declare `0x09`, but CoreHID
  delivers the Set Report anyway (confirmed on hardware), so we parse it with no
  descriptor change: `[id, 0,0,0x09,0,0x0F, LT, RT, L, R, dur, delay, loop]`.

Magnitudes are 0..100 percent, rescaled to 0..65535 for the NS2 LRA encoder. NS2
Pro has no trigger motors, so trigger magnitudes fold into the main motor via
`max`. `refreshInterval` is 80 ms: Xbox hosts send a start frame and a stop frame
~1 s apart, but the NS2 motor times out after ~300 ms, so the coordinator re-sends
to keep it alive between host frames.

## Two Xbox profiles: BLE (this file) vs SDL/USB GIP

This file (`XboxSeriesOutput`, PID `0x0B13`) is the BLE HID-gamepad presentation —
it serves **GameController.framework, the web Gamepad API, and Steam** (Steam
reads Xbox via macOS's MFi backend; rumble via report `0x09`).

SDL **HIDAPI-only** consumers (Dolphin, etc.) speak the GIP protocol and need GIP
`0x20` `GIP_CMD_INPUT` frames, which the faithful BLE profile doesn't send — so
they get no input from it. (Note: GameController claiming a device does **not**
block HIDAPI reads — the Switch Pro spoof works in GameController and SDL at once.
One descriptor *can* serve both: HID Game Pad report `0x01` + appended GIP `0x20`
reports. We keep them as two profiles by preference, not necessity — see below.)

The separate profile **`XboxSeriesSDLOutput` (`Xbox (SDL/USB)`)** — same PID
`0x0B13`, distinguished by descriptor — uses the verbatim real-USB all-vendor GIP
descriptor (reports `0x20` input, `0x07` virtual-key/Guide, `0x01`/`0x05` output).
It streams `0x20` (SDL auto-completes init on the first one,
`SDL_hidapi_xboxone.c:1232`) and parses `0x09` rumble. The `0x07` Guide
virtual-key is an **INTERNAL** GIP packet the host ACKs, so it's emitted **only on
Guide press/release** (a stateful `XboxGIPSession` actor) — sending it every frame
made the host ACK ~70×/sec, flooding the log. It has no GameController/web gamepad.

Why two profiles instead of one merged descriptor (Game Pad + GIP reports)? Not
necessity — a merged profile *does* work for all four (GameController, web, Steam,
Dolphin). It's avoided only for two **cosmetic** reasons: (1) SDL logs `01 20 …`
ACK noise because it misreads our report-`0x01` HID frames as GIP (DEBUG-only,
gone in release); (2) joypad.ai's WebHID raw view garbles by merging `0x01` +
`0x20`. If those don't matter, the two could be collapsed into one. See
`XboxSeriesSDLOutput.swift`.
