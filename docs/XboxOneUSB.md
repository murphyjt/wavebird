# Wired Xbox One over USB — how it works

*Baseline: upstream `b04a072` (Aug 31, 2026), the latest commit on `main`.*

Reference for `Transports/USB/GIPCodec.swift`, `Transports/USB/XboxUSBTransport.swift`
and `Profiles/XboxOneProfile.swift`. The wire facts documented here (field
layouts, command numbers, GUIDs) are interoperability data of the GIP
protocol. The Linux driver project medusalix/xone was consulted as a reference for
those facts; the code in this project is an independent implementation of the
documented format.

## The shape of the problem

Original Xbox One pads (1537/1697) have **no Bluetooth radios** — when wired
they talk Microsoft's **GIP** on a vendor-specific interface:

| USB descriptor field | Value |
|---|---|
| `bInterfaceClass` | `0xFF` (vendor) |
| `bInterfaceSubClass` | `0x47` |
| `bInterfaceProtocol` | `0xD0` |
| endpoints (intf 0) | interrupt IN `0x81`, interrupt OUT `0x01`, 64 B |
| interface 1 | isochronous audio (headset) — ignored |

macOS has no driver for that class → the pad is invisible. WaveBird's answer
is the same as for Switch 2: **we are the driver**. The USB transport parses
GIP and the stock `xboxSeries` output profile publishes a real Xbox HID
device through CoreHID, so macOS sees a standard "Xbox Wireless Controller"
— identical to the Bluetooth profile (PID `0x0B13`), which Apple's
`XboxOneHIDServicePlugin` binds as a `GCController` with no handshake at all.

**Identification is by interface, not vendor**: any device exposing the GIP
vendor interface is a candidate (Microsoft pads, GameSir, PowerA, 8BitDo,
Hori, PDP, …); the identify handshake confirms it's a gamepad. Only the
wireless-adapter dongles (which reuse the class but speak MT76 802.11) are
refused outright — they're matched by PID (`0x02E6/0x02FE/0x02F9/0x091E`).

## GIP framing (bus/protocol.c)

```
[command][options][sequence][packet_length varint][chunk_offset varint?][payload…]
  options: client id (nibble) | ACK 0x10 | INTERNAL 0x20 | CHUNK_START 0x40 | CHUNK 0x80
```

- varint: 7 bits/byte LE, high bit = continue (`gip_encode/decode_varint`).
- header length is rounded **up to even**: when odd, the last length byte gets
  bit 7 set and a `0x00` pad byte follows (decoder consumes the pad as a
  continuation byte that contributes 0). `GIPHeaderCodec` does exactly this.
- payload max 58 B (`GIP_PKT_MAX_LENGTH`). Chunked transfer (identify info is
  ~1–3 KB): first chunk `CHUNK_START|CHUNK|ACK` with `chunk_offset = TOTAL`;
  mid chunks `CHUNK` with running offset; last chunk adds `ACK`; then a
  **header-only chunk** (`packet_length 0`, `chunk_offset = TOTAL`) completes
  it. Receiver: `CHUNK_START` allocates the buffer and rewrites the current
  chunk's offset to 0.
- Every packet with `ACK` is answered by an internal ACK
  (`0x01`): 9-byte payload `[00, cmd, clientId, len u16le, pad[2],
  remaining u16le]` where `len = acked chunk_offset + acked packet_length`
  (first chunk: 0 + len) and `remaining = transferTotal − len` (chunked only).
- sequences: per-adapter counter, must never be 0.

## Handshake (the only dance)

1. Controller sends **ANNOUNCE** (`0x02`, INTERNAL, 28 B:
   `addr[6], u16?, vid, pid, fw[8], hw[8]`).
2. Host sends **IDENTIFY** (`0x04`, INTERNAL, no payload).
3. Controller streams the **identify info block** (chunked): 16 unknown bytes,
   8 × u16le offsets (client_commands, firmware_versions, audio_formats,
   capabilities_out/in, classes, interfaces, hid_descriptor), then elements.
   Offsets are measured from `payload + 16` (xone does `data += sizeof(unknown)`
   and parses from there). `classes` element: `count`, then per class
   `[u16le len][ascii]` — the gamepad class is
   `Windows.Xbox.Input.Gamepad`.
4. Host sends **POWER ON** (`0x05`, mode `0x00`) + best-effort **LED** (`0x0A`).
5. Input reports flow (`0x20`, no INTERNAL bit).

## Input report (driver/gamepad.c `gip_gamepad_op_input`)

14 base bytes:

```
u16le buttons | u16le LT (0…1023) | u16le RT (0…1023)
s16 LX | s16 LY | s16 RX | s16 RY   (center 0, Y positive = UP)
```

buttons bits: MENU 1<<2, VIEW 1<<3, A 1<<4, B 1<<5, X 1<<6, Y 1<<7,
dpad 1<<8…11, LB 1<<12, RB 1<<13, L3 1<<14, R3 1<<15 (bits 0–1 reserved —
they carry our synthetic Guide/Share channels).

**Guide:** comes as `0x07` virtual-key packets (`[down, 0x5B]`), not a button
bit. **Share:** pads that advertise the Share GUID (1697 S, Series X|S wired,
Elite 2, GameSir G7 Pro, …) carry a Share byte at `len−18` from the end of
the input packet (`len−26` when the pad also advertises the DLI counter GUID
— 8 extra bytes; xone's `gip_gamepad_op_input`). The transport latches both
onto the packet's two reserved button bits (bit 0 = Guide, bit 1 = Share) —
`XboxOneProfile` maps them to `.home` / `.capture`. The original 1537 has
neither GUID and simply never emits them.

## Rumble (gip_send_rumble → 0x09, 9 B)

`[00, motors, LT, RT, L, R, duration, delay, repeat]`,
motors: R `0x01|L 0x02|RT 0x04|LT 0x08`. Amplitudes 0…100
(`(mag × 100 + 32767) / 65535`). The LT/RT fields carry trigger-motor
amplitudes (Series impulse triggers, GameSir trigger rumble): the Xbox output
session adds them to `RumbleCommand` and the GIP encoder puts them on the
wire; pads without trigger motors ignore them. Stop frame (xone's init frame,
also required to *start* input on some pads): motors `0x0F`, amps 0, duration
`0xFF`, repeat `0xEB`. WaveBird's 10 ms rumble-refresh requirement matches
xone's 10 ms retransmit timer (`GIP_GP_RUMBLE_DELAY`).

## Integration map

- `XboxUSBTransport` (Transport conformance): IOKit hot-plug on **any** device
  exposing the `0xFF/0x47/0xD0` interface, adapter PIDs excluded → the
  coordinator's existing `.discovered → connect → ready` flow, unchanged.
- Third-party pads (GameSir `0x3537`, PowerA `0x24C6`, 8BitDo `0x2DC8`,
  Hori `0x0F0D`, PDP `0x0E6F`, …) work with no discovery changes. GameSir
  pads must be in GIP mode (hold Xbox + Share ~3 s; GIP USB reports as
  `3537:1022`, XInput mode as `3537:0575`).
- Handshake + chunk ACKs happen inside the transport (they're protocol-level);
  the coordinator only sees `.reportReceived(reportID: nil, <14-byte input>)`.
- Serial: `xbox-<announce address hex>` via the new `.deviceMetadata` event.
- Profile: `XboxOneProfile.parseUSBReport` → `ControllerState`
  (12-bit centered sticks, triggers >>2, shoulders), `encodeRumble` → GIP.
- Output: stock `xboxSeries` profile — no output-side changes at all.
