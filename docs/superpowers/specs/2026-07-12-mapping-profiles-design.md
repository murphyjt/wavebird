# Mapping Profiles — design

2026-07-12. Origin: [issue #2](https://github.com/murphyjt/wavebird/issues/2)
(map NS2 Pro GL/GR to other buttons) plus the macOS 27 beta regression that
removed VHIDs from System Settings → Game Controllers, taking system-level
remapping with it. Scope grew deliberately from "GL/GR option" to reusable,
Apple-style **mapping profiles**.

## What ships

- GL/GR (NS2 Pro) and SL/SR (Joy-Con) decoded from report 0x05.
- **Profiles**: named, user-created mappings with a fixed base emulated
  controller (Xbox, DualShock 4, DualSense, Switch Pro). Built-in defaults
  ("Default Xbox", …) exist per shipping mode, read-only.
- Per-controller profile selection replaces the raw output-mode picker
  (same "Use profile" UI slot; legacy setting honored).
- Buttons only on the source side: every dropdown choice is a physical
  button. Target rows are whatever the base's catalog declares — that
  includes LT/RT (driven as digital full-pull when remapped). Sticks and
  dpad-as-directions are not rows in v1; analog axes pass through
  untouched.

## Decisions (with the reasoning that picked them)

| Decision | Choice | Why |
| --- | --- | --- |
| Scope | General remapping via profiles | Issue #2 asks only GL/GR, but macOS 27 removed the system remapping surface WaveBird relied on |
| Remap layer | Per-output-mode (profile carries a base mode) | Mappings speak the emulated controller's vocabulary; matches what macOS Game Controllers settings offered |
| Input surface | Buttons only | Small matrix; covers GL/GR and the macOS-27 gap; axes stay pass-through |
| Engine | Catalog + pre-encode state rewrite | Encoders untouched → existing hardware validation carries over; pure function → golden-vector testable |
| Mapping direction | Rows = emulated controls, dropdown = Nintendo buttons | Row list fixed by base → profile is a stable document reusable across controller types; dropdown is the NS2 union vocabulary |
| Profile contents (v1) | Base mode + button mapping only | Rumble tuning / axis inversion / Guide routing stay per-serial; gyro-source and haptics deferred (see Future work) |

Mapping semantics: each output control has exactly one source — Default
(the base mode's stock wiring), a physical button, or Off. Duplicates
allowed (one physical button may drive several controls); no swap
inference (remapping A ← ZL does not touch rows ZL drives by default).
Joy-Cons need no special casing: selection keys by presented identity
(solo serial or the `"Lserial+Rserial"` pair key) and the pair's
vocabulary is the union of both halves.

## Report 0x05 additions

Source: ndeadly `hid_reports.md`, Input Report 0x05 → Button Format.
**Needs hardware confirmation — these bits have never been read by WaveBird.**

- `ButtonSet.gl = 1 << 23`, `ButtonSet.gr = 1 << 24` (next free raw bits).
- `NS2ButtonBits.pro`: wire bit 24 → `.gr` (byte 3 · 0x01), wire bit 25 →
  `.gl` (byte 3 · 0x02).
- `NS2ButtonBits.joyConR`: wire bit 4 → `.sr` (byte 0 · 0x10), bit 5 →
  `.sl` (byte 0 · 0x20).
- `NS2ButtonBits.joyConL`: wire bit 20 → `.sr` (byte 2 · 0x10), bit 21 →
  `.sl` (byte 2 · 0x20).

`ButtonSet.sl`/`.sr` already exist; only the table entries are new.

## Data model

**`PhysicalButton`** — `String`-raw-value enum over the NS2 union
vocabulary: `a b x y l r zl zr gl gr sl sr z c plus minus start home
capture stickL stickR dpadUp dpadDown dpadLeft dpadRight`. Raw values are
the persistence format. Each input profile declares its hardware subset;
the merged pair is the union of L+R. The editor dropdown shows the full
union grouped by family ("GL (Pro)", "SL (Joy-Con)", "Z (GC)").

**`OutputControl` catalog** — each output mode declares an ordered list;
it is simultaneously the editor's row list and the transform's spec:

- `id`: stable mode-prefixed string (`"xbox.a"`, `"xbox.leftBumper"`) —
  persistence key, never renamed.
- `displayName`: "A Button", "Left Bumper", …
- `driver`: the canonical `ControllerState` field the mode's existing
  encoder reads for this control (a `ButtonSet` member or a
  `StandardShoulders` field). E.g. Xbox "A Button" reads `.b`.
- `defaultSource`: the `PhysicalButton` driving it in stock wiring.

**`MappingProfile`** — the persisted entity:

- `id`: UUID
- `name`: user-visible, editable
- `baseModeID`: `HIDOutputCatalog` entry ID; **fixed after creation**
  (control IDs are mode-prefixed, so a base change would orphan every
  entry; "Duplicate to another base" is future work)
- `mapping`: sparse `[outputControlID: choice]`, choice = physical-button
  raw value or the sentinel `"off"`; absent = Default

**Built-in defaults** are synthesized from the catalog at runtime under
stable well-known IDs — never stored, never editable or deletable. DEBUG
builds synthesize defaults for DEBUG-only modes automatically.

**Persistence:**

- New key `WaveBird.mappingProfiles` = JSON `[UUID: MappingProfile]`.
  Decode-with-recovery per record: one corrupt record is dropped, the
  rest survive (new data, so it starts with the resilient shape).
- `KnownController` gains optional `preferredProfileID: String?` —
  additive, old blobs decode.
- Legacy migration by interpretation, not rewrite: `preferredProfileID`
  absent + `preferredOutputModeID` set → resolve to that mode's default
  profile. The legacy field is never removed, so downgrades keep working.

## Engine & data flow

**Resolution.** At `.ready` and on profile change, the coordinator
resolves `preferredProfileID` → `MappingProfile` → base mode's
`HIDOutputProfile` (VHID identity, unchanged) + a precomputed
`ResolvedMappingSpec`. A profile switch with a different base goes
through the existing `republishVirtualHID`; same base, different mapping
only swaps the spec — no republish.

**`ResolvedMappingSpec`** — computed once at resolution, not per report:
for each catalog entry, the physical source to read (default / remapped /
off) plus the driver field to write, and an `isDefault` flag for the
whole spec.

**Transform.** One pure function
`applyMapping(state, spec) -> ControllerState`, run in the per-device
dispatch task after `invertingY` and before `buildReport` (after the
merge for the pair path). It synthesizes fresh `buttons` +
`StandardShoulders` from the physical press-set. `isDefault` short-
circuits to the untouched state, keeping today's hot path bit-exact and
zero-cost. GC nuance: trigger rows at Default pass the parser's analog
values through; explicitly remapped trigger rows synthesize digital
0/0xFF.

**Live updates.** The spec is sampled through the existing
`OSAllocatedUnfairLock<Snapshot>` idiom (a per-connection box, same shape
as rumble/axis settings), so committing a profile edit updates every
connected controller using that profile without restarting dispatch
tasks.

**Encoders untouched.** No `buildReport`, descriptor, or wire byte
changes at default. The only encoder-adjacent addition is each mode's
~15-entry catalog.

## UI

**Settings → Profiles tab** (existing toggles move to a General tab).
Apple-style list: profile name, base-controller icon, "N controllers"
subtitle (known controllers assigned); `+`/`−` beneath. Defaults show no
`−` and open read-only.

**Editor sheet** (`+` or click a custom profile): Name field, then the
base's catalog rows — icon + display name, `Picker` per row: Default /
Off / physical buttons grouped by family. **Cancel/Done** on a draft
copy; Done commits and pushes the new spec to connected controllers.

**"Use profile" picker** (`ControllerDetailSheet` → General): same slot,
now lists a Defaults section (four built-ins) + Custom section. Legacy
users see their previous mode preselected via the migration rule. Bottom
item **"Manage Profiles…"** opens Settings → Profiles — the issue-#2
user's path: detail sheet → Manage Profiles → `+` → map GL/GR → select.

No menu-bar changes in v1.

## Edge cases

- **Delete-in-use**: at delete time, every `KnownController` referencing
  the profile is rewritten to the base's default-profile ID — same VHID
  identity, stock mapping.
- **Stale/unknown profile ID** (e.g. release build seeing a DEBUG-mode
  reference): falls through the existing unknown-mode resolution.
- **Source button absent on hardware** (GL row, GameCube pad): row never
  fires; no warning in v1.
- **Guide ← Off** (Xbox): `.home` never reaches the session, so neither
  report 0x01 nor GIP 0x07 carries it; the per-serial Guide-routing
  toggles are untouched and still route whatever arrives.
- **Pair form/split/promote**: pair key and solo serials hold independent
  selections; resolution re-runs through the existing republish paths.

## Testing

Unit (golden-vector suites, `StickMappingTests` pattern):

- Transform: empty mapping bit-identical; GL→A drives the `.b`-equivalent
  output; GL→Left Trigger synthesizes digital full-pull; Off suppresses a
  default-firing control; GC analog triggers survive Default and go
  digital when remapped.
- Parsing: synthetic report-0x05 frames for the new GL/GR and SL/SR
  table entries.
- Persistence: `MappingProfile` round-trip; decode-with-recovery drops
  one corrupt record, keeps the rest; legacy `preferredOutputModeID`
  resolution.
- Catalog invariants: IDs unique and mode-prefixed; every shipping mode
  has a catalog.

Hardware checklist (manual pass, new-code items first):

1. GL/GR on a real NS2 Pro (byte 3 · 0x01/0x02 per ndeadly — unverified);
   SL/SR on real Joy-Cons, solo and paired.
2. Custom Xbox profile: GL→A visible in hardwaretester/Control.app;
   GL→LT reads as full analog pull.
3. Default profiles behave identically to today in one known consumer
   per mode (the `isDefault` identity path makes this near-formality).
4. Live edit while connected applies without republish; base-different
   switch republishes cleanly.

## Future work (noted, not designed)

- Gyro-source selection per profile — blocked on merged-pair IMU
  forwarding (PLAN item 5).
- Haptics options per profile — needs a single-owner decision vs the
  per-serial rumble `intensity` setting.
- Duplicate-profile action (incl. duplicate-to-another-base).
- Dpad directions as four remappable rows.
- Menu-bar profile submenu per controller.
- Profile import/export. Dolphin INI / SDL `gamecontrollerdb` formats
  were considered and rejected as the internal format: they describe
  host-side mappings of an SDL-visible device, one layer above WaveBird.
