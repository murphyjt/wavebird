# SDL Virtual Transport for the Switch 2 Driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach SDL3's HIDAPI Switch 2 driver to run over a software HID bridge (WaveBird's `ns2Relay` mode) by adding a `VIRTUAL` bus type and a transport that tunnels commands through HID reports `0x80`/`0x81` instead of libusb bulk endpoints.

**Architecture:** Bus-type plumbing (public enum, vendored hidapi enum, macOS + Linux backends, `SDL_HIDAPI_Device.is_virtual`) is mechanical. In `SDL_hidapi_switch2.c`, the existing USB init is split into "acquire libusb transport" and "initialise the controller"; the command send/receive pair gets a virtual body (HID write of `0x80`, HID read loop for `0x81`) selected by `is_virtual`. Everything above the command layer (calibration, state parsing, rumble, LED, sensors) is unchanged.

**Tech Stack:** C (SDL3 main), CMake/Ninja (`build-mac/` → `install-mac/`), `test/testcontroller`.

**Spec:** `/Users/joshua/Developer/WaveBird/docs/superpowers/specs/2026-09-10-ns2-relay-design.md` — §"The HID contract" and §"SDL design". The WaveBird half is `docs/superpowers/plans/2026-09-10-ns2-relay-wavebird.md`. Both plans implement one contract; the SDL header comment in Task 2 is the canonical copy.

## Global Constraints

- Repository: `/Users/joshua/Developer/SDL`, branch off `main` at `04b2fb804`. **Do not** `git stash pop` the stash named "wavebird is_virtual patch (pre-relay design)" — it is superseded.
- Work on a branch: `git switch -c switch2-virtual-transport`.
- Enum value: `SDL_HID_API_BUS_VIRTUAL = 0x05` and `HID_API_BUS_VIRTUAL = 0x05` are **placeholders** until the SDL maintainer picks a value in the upstream issue. Both must stay equal to each other.
- Windows has no virtual-bus signal in its hidapi, so no detection is added there — but the enum addition still needs `case HID_API_BUS_VIRTUAL:` in `src/hidapi/windows/hid.c`'s `-Wswitch` suppression group (upstream CI builds Windows with `-Werror`).
- USB path bodies of `SendCommand`/`RecvResponse` (renamed from `SendBulkData`/`RecvBulkData`) are unchanged byte-for-byte. `UpdateDevice`'s USB behaviour is unchanged: the `0x81` skip is virtual-only.
- Contract numbers (copied from the spec; every one appears in the header comment):
  - Request: Output Report `0x80`, 64 payload bytes → `hid_write` buffer is 65 bytes (`[0x80] + 64`).
  - Response: Input Report `0x81`, 80 payload bytes → `hid_read` buffer is 81 bytes (`[0x81] + 80`).
  - Response deadline 2000 ms; state reports (`0x05`) are dropped while waiting.
  - Bridge rewrites frame byte 2 (`0x00` → `0x01`); SDL sends `0x00` as it does today.
- Build: `cmake --build /Users/joshua/Developer/SDL/build-mac` then `cmake --install /Users/joshua/Developer/SDL/build-mac` (prefix is already `install-mac/`, `SDL_HIDAPI_JOYSTICK=ON`, `SDL_TESTS=ON`).
- Run: `/Users/joshua/Developer/SDL/build-mac/test/testcontroller`.
- Commit style: SDL upstream style (imperative title, short body). No AI attribution trailers on commits intended for the upstream PR; keep the trailer out of this repo.
- There are no unit tests for HIDAPI drivers in SDL; "test" here means it compiles with `-Wall -Werror`-equivalent cleanliness (SDL's default flags) and `testcontroller` runs. Hardware validation is in Task 3 and is mandatory before the upstream PR.

## File Structure

- Modify: `include/SDL3/SDL_hidapi.h` — public `SDL_HID_API_BUS_VIRTUAL`.
- Modify: `src/hidapi/hidapi/hidapi.h` — vendored `HID_API_BUS_VIRTUAL`.
- Modify: `src/hidapi/mac/hid.c` — map `kIOHIDTransportVirtualValue` in both transport switches.
- Modify: `src/hidapi/linux/hid.c` — admit and map `BUS_VIRTUAL`.
- Modify: `src/joystick/hidapi/SDL_hidapijoystick_c.h` — `bool is_virtual`.
- Modify: `src/joystick/hidapi/SDL_hidapijoystick.c` — set `is_virtual`; propagate to the combined Joy-Con device.
- Modify: `src/hidapi/SDL_hidapi.c` — exempt `HID_API_BUS_VIRTUAL` from the libusb-only whitelist in `SDL_HIDAPI_ShouldIgnoreDevice` (all four NS2 PIDs are on it; without this the bridge device is dropped at enumeration).
- Modify: `src/hidapi/windows/hid.c` — the one `case` label above.
- Modify: `src/joystick/hidapi/SDL_hidapi_switch2.c` — the driver changes.

---

### Task 1: Bus-type plumbing

**Files:**
- Modify: `include/SDL3/SDL_hidapi.h:78-104`
- Modify: `src/hidapi/hidapi/hidapi.h:124-149`
- Modify: `src/hidapi/mac/hid.c:551-568` and `:671-698`
- Modify: `src/hidapi/linux/hid.c:47-49`, `:751-759`, `:786-856`
- Modify: `src/joystick/hidapi/SDL_hidapijoystick_c.h:96`
- Modify: `src/joystick/hidapi/SDL_hidapijoystick.c:937`, `:1110-1114`

**Interfaces:**
- Consumes: nothing new.
- Produces: `SDL_HID_API_BUS_VIRTUAL` (public), `HID_API_BUS_VIRTUAL` (internal hidapi), `SDL_HIDAPI_Device.is_virtual` (true when `info->bus_type == SDL_HID_API_BUS_VIRTUAL`).

- [ ] **Step 1: Branch**

```bash
cd /Users/joshua/Developer/SDL
git switch -c switch2-virtual-transport
git status --short   # expect only "?? install-mac/"
```

- [ ] **Step 2: Public enum**

In `include/SDL3/SDL_hidapi.h`, change lines 99–104 from:

```c
    /** SPI bus
       Specifications:
       https://www.microsoft.com/download/details.aspx?id=103325 */
    SDL_HID_API_BUS_SPI = 0x04

} SDL_hid_bus_type;
```

to:

```c
    /** SPI bus
       Specifications:
       https://www.microsoft.com/download/details.aspx?id=103325 */
    SDL_HID_API_BUS_SPI = 0x04,

    /** Virtual bus
       A software bridge publishing a virtual HID device (macOS CoreHID
       "Virtual" transport, Linux uhid with BUS_VIRTUAL). The bridge owns
       the physical link; drivers must not assume a USB or Bluetooth
       backend behind it. */
    SDL_HID_API_BUS_VIRTUAL = 0x05

} SDL_hid_bus_type;
```

- [ ] **Step 3: Vendored hidapi enum**

In `src/hidapi/hidapi/hidapi.h`, change lines 145–149 from:

```c
			/** SPI bus
			   Specifications:
			   https://www.microsoft.com/download/details.aspx?id=103325 */
			HID_API_BUS_SPI = 0x04,
		} hid_bus_type;
```

to:

```c
			/** SPI bus
			   Specifications:
			   https://www.microsoft.com/download/details.aspx?id=103325 */
			HID_API_BUS_SPI = 0x04,

			/** Virtual bus
			   A software bridge publishing a virtual HID device; the bridge
			   owns the physical link. */
			HID_API_BUS_VIRTUAL = 0x05,
		} hid_bus_type;
```

- [ ] **Step 4: macOS backend — both transport switches**

In `src/hidapi/mac/hid.c`, `get_bus_type` (lines 562–566), change:

```c
		} else  if (CFStringCompare((CFStringRef)transport_prop, CFSTR(kIOHIDTransportSPIValue), 0) == kCFCompareEqualTo) {
			bus_type = HID_API_BUS_SPI;
		}
```

to:

```c
		} else  if (CFStringCompare((CFStringRef)transport_prop, CFSTR(kIOHIDTransportSPIValue), 0) == kCFCompareEqualTo) {
			bus_type = HID_API_BUS_SPI;
		} else  if (CFStringCompare((CFStringRef)transport_prop, CFSTR(kIOHIDTransportVirtualValue), 0) == kCFCompareEqualTo) {
			bus_type = HID_API_BUS_VIRTUAL;
		}
```

and in `create_device_info_with_usage` (lines 696–698), change:

```c
		} else  if (CFStringCompare((CFStringRef)transport_prop, CFSTR(kIOHIDTransportSPIValue), 0) == kCFCompareEqualTo) {
			cur_dev->bus_type = HID_API_BUS_SPI;
		}
```

to:

```c
		} else  if (CFStringCompare((CFStringRef)transport_prop, CFSTR(kIOHIDTransportSPIValue), 0) == kCFCompareEqualTo) {
			cur_dev->bus_type = HID_API_BUS_SPI;
		} else  if (CFStringCompare((CFStringRef)transport_prop, CFSTR(kIOHIDTransportVirtualValue), 0) == kCFCompareEqualTo) {
			cur_dev->bus_type = HID_API_BUS_VIRTUAL;
		}
```

`kIOHIDTransportVirtualValue` (`"Virtual"`) is declared in `<IOKit/hid/IOHIDKeys.h>`, already included.

- [ ] **Step 5: Linux backend**

In `src/hidapi/linux/hid.c`, after the `BUS_SPI` guard (lines 47–49), add:

```c
#ifndef BUS_VIRTUAL
#define BUS_VIRTUAL 0x06
#endif
```

In the filter switch (lines 751–759), add `case BUS_VIRTUAL:` to the admitted cases:

```c
	switch (bus_type) {
		case BUS_BLUETOOTH:
		case BUS_I2C:
		case BUS_USB:
		case BUS_SPI:
		case BUS_VIRTUAL:
			break;

		default:
			goto end;
	}
```

In the mapping switch (before the `default:` at line 851), add:

```c
		case BUS_VIRTUAL:
			cur_dev->manufacturer_string = wcsdup(L"");
			cur_dev->product_string = utf8_to_wchar_t(product_name_utf8);

			cur_dev->bus_type = HID_API_BUS_VIRTUAL;

			break;
```

- [ ] **Step 6: `is_virtual` on the device**

In `src/joystick/hidapi/SDL_hidapijoystick_c.h` line 96, change:

```c
    bool is_bluetooth;
```

to:

```c
    bool is_bluetooth;
    bool is_virtual;    // Software HID bridge (SDL_HID_API_BUS_VIRTUAL); no USB or Bluetooth backend behind it
```

In `src/joystick/hidapi/SDL_hidapijoystick.c` line 937, change:

```c
    device->is_bluetooth = (info->bus_type == SDL_HID_API_BUS_BLUETOOTH);
```

to:

```c
    device->is_bluetooth = (info->bus_type == SDL_HID_API_BUS_BLUETOOTH);
    device->is_virtual = (info->bus_type == SDL_HID_API_BUS_VIRTUAL);
```

In the combined Joy-Con block (lines 1110–1114), change:

```c
            if (children[0]->is_bluetooth || children[1]->is_bluetooth) {
                info.bus_type = SDL_HID_API_BUS_BLUETOOTH;
            } else {
                info.bus_type = SDL_HID_API_BUS_USB;
            }
```

to:

```c
            if (children[0]->is_bluetooth || children[1]->is_bluetooth) {
                info.bus_type = SDL_HID_API_BUS_BLUETOOTH;
            } else if (children[0]->is_virtual || children[1]->is_virtual) {
                info.bus_type = SDL_HID_API_BUS_VIRTUAL;
            } else {
                info.bus_type = SDL_HID_API_BUS_USB;
            }
```

(The combined device uses `SDL_HIDAPI_DriverCombined`, which never initialises a transport; this only keeps `is_virtual` truthful on the parent.)

- [ ] **Step 7: Build**

```bash
cmake --build /Users/joshua/Developer/SDL/build-mac
```

Expected: builds with no new warnings. (Linux changes can't be compiled here; they mirror the `BUS_SPI` pattern exactly and will be exercised by upstream CI.)

- [ ] **Step 8: Commit**

```bash
cd /Users/joshua/Developer/SDL
git add include/SDL3/SDL_hidapi.h src/hidapi/hidapi/hidapi.h src/hidapi/mac/hid.c src/hidapi/linux/hid.c src/joystick/hidapi/SDL_hidapijoystick_c.h src/joystick/hidapi/SDL_hidapijoystick.c
git commit -m "hidapi: add a VIRTUAL bus type for software HID bridges

macOS reports CoreHID virtual devices with Transport = \"Virtual\"; Linux
uhid devices carry BUS_VIRTUAL (previously filtered out entirely). Expose
both as SDL_HID_API_BUS_VIRTUAL and set SDL_HIDAPI_Device.is_virtual so
drivers can avoid assuming a USB backend. Enum value is provisional."
```

---

### Task 2: Switch 2 driver virtual transport

**Files:**
- Modify: `src/joystick/hidapi/SDL_hidapi_switch2.c:157-200` (send/recv), `:323-327` (Bluetooth stub stays), `:368-507` (InitUSB split), `:509-531` (InitDevice), `:1246-1283` (UpdateDevice), plus every `SendBulkData`/`RecvBulkData` call site (`:245`, `:249`, `:266`, `:271`, `:499`, `:503`, `:674`, `:678`, `:1179`, `:1180`).

**Interfaces:**
- Consumes: `device->is_virtual` (Task 1), `SDL_hid_write`, `SDL_hid_read_timeout`, `SDL_GetTicks`.
- Produces (all `static`):
  - `int SendCommand(SDL_DriverSwitch2_Context *ctx, const Uint8 *data, unsigned size)` — USB: old `SendBulkData` body; virtual: `hid_write` of `[0x80] + data` padded to 65 bytes, returns `size`.
  - `int RecvResponse(SDL_DriverSwitch2_Context *ctx, Uint8 *data, unsigned size)` — USB: old `RecvBulkData` body; virtual: read loop for `0x81` up to 2000 ms, copies up to `size` bytes, returns count or 0 on timeout, `<0` on read error.
  - `bool HIDAPI_DriverSwitch2_InitUSBTransport(SDL_HIDAPI_Device *)` — libusb handle, endpoints, claim.
  - `bool HIDAPI_DriverSwitch2_InitController(SDL_HIDAPI_Device *)` — flash reads + init sequence (transport-agnostic).
  - `bool HIDAPI_DriverSwitch2_InitUSB(SDL_HIDAPI_Device *)` — calls both.
  - `bool HIDAPI_DriverSwitch2_InitVirtual(SDL_HIDAPI_Device *)` — calls `InitController` only; carries the contract header comment.

- [ ] **Step 1: Replace the bulk helpers with transport-dispatching ones**

Replace `SendBulkData` and `RecvBulkData` (lines 157–200) with:

```c
#define SWITCH2_VIRTUAL_REQUEST_REPORT_ID   0x80
#define SWITCH2_VIRTUAL_RESPONSE_REPORT_ID  0x81
#define SWITCH2_VIRTUAL_REQUEST_SIZE        64
#define SWITCH2_VIRTUAL_RESPONSE_SIZE       80
#define SWITCH2_VIRTUAL_RESPONSE_TIMEOUT_MS 2000

static int SendCommand(SDL_DriverSwitch2_Context *ctx, const Uint8 *data, unsigned size)
{
    if (ctx->device->is_virtual) {
        // Virtual transport: the command frame rides in Output Report 0x80.
        // The bridge takes the first 8 + data[5] bytes and forwards them.
        Uint8 report[1 + SWITCH2_VIRTUAL_REQUEST_SIZE];
        if (size > SWITCH2_VIRTUAL_REQUEST_SIZE) {
            return SDL_SetError("Command too large for the virtual transport: %u", size);
        }
        SDL_zeroa(report);
        report[0] = SWITCH2_VIRTUAL_REQUEST_REPORT_ID;
        SDL_memcpy(&report[1], data, size);
        if (SDL_hid_write(ctx->device->dev, report, sizeof(report)) < 0) {
            return -1;
        }
        return (int)size;
    }

    int transferred;
    int res = ctx->libusb->bulk_transfer(ctx->device_handle,
                ctx->out_endpoint,
                (Uint8 *)data,
                size,
                &transferred,
                1000);
    if (res < 0) {
        return res;
    }
    return transferred;
}

static int RecvResponse(SDL_DriverSwitch2_Context *ctx, Uint8 *data, unsigned size)
{
    if (ctx->device->is_virtual) {
        // Virtual transport: the response arrives as Input Report 0x81.
        // State reports (0x05) that land while we wait are dropped, matching
        // the bulk path where responses and state never share a pipe.
        // Returns 0 on timeout — the same "short read" the bulk path yields
        // when the controller stays silent — so callers that ignore the
        // reply keep working.
        Uint8 report[1 + SWITCH2_VIRTUAL_RESPONSE_SIZE];
        Uint64 deadline = SDL_GetTicks() + SWITCH2_VIRTUAL_RESPONSE_TIMEOUT_MS;
        for (;;) {
            Uint64 now = SDL_GetTicks();
            if (now >= deadline) {
                return 0;
            }
            int res = SDL_hid_read_timeout(ctx->device->dev, report, sizeof(report), (int)(deadline - now));
            if (res < 0) {
                return res;
            }
            if (res == 0) {
                return 0;
            }
            if (report[0] != SWITCH2_VIRTUAL_RESPONSE_REPORT_ID) {
                continue;
            }
            unsigned count = (unsigned)res - 1;
            if (count > size) {
                count = size;
            }
            SDL_memcpy(data, &report[1], count);
            return (int)count;
        }
    }

    int transferred;
    int total_transferred = 0;
    int res;

    while (size > 0) {
        unsigned current_read = size;
        if (current_read > 64) {
            current_read = 64;
        }
        res = ctx->libusb->bulk_transfer(ctx->device_handle,
                    ctx->in_endpoint,
                    data,
                    current_read,
                    &transferred,
                    100);
        if (res < 0) {
            return res;
        }
        total_transferred += transferred;
        size -= transferred;
        data += current_read;
        if ((unsigned) transferred < current_read) {
            break;
        }
    }

    return total_transferred;
}
```

- [ ] **Step 2: Rename every call site**

Replace all remaining occurrences: `SendBulkData(` → `SendCommand(` and `RecvBulkData(` → `RecvResponse(`. Sites: `UpdateSlotLED` (245, 249), `ReadFlashBlock` (266, 271), the init loop (499, 503), `SetJoystickSensorsEnabled` (674, 678), `HandleStatePacket` (1179, 1180).

```bash
grep -n "SendBulkData\|RecvBulkData" src/joystick/hidapi/SDL_hidapi_switch2.c   # expect no output after the edits
```

- [ ] **Step 3: Split `InitUSB`**

Replace `HIDAPI_DriverSwitch2_InitUSB` (lines 368–507) with three functions. The first is lines 368–390 of the old body, the second is lines 392–506 verbatim (only the name and the missing `res` declaration change), the third composes them:

```c
static bool HIDAPI_DriverSwitch2_InitUSBTransport(SDL_HIDAPI_Device *device)
{
    SDL_DriverSwitch2_Context *ctx = (SDL_DriverSwitch2_Context *)device->context;

    if (!SDL_InitLibUSB(&ctx->libusb)) {
        return false;
    }

    ctx->device_handle = (libusb_device_handle *)SDL_GetPointerProperty(SDL_hid_get_properties(device->dev), SDL_PROP_HIDAPI_LIBUSB_DEVICE_HANDLE_POINTER, NULL);
    if (!ctx->device_handle) {
        return SDL_SetError("Couldn't get libusb device handle");
    }

    if (!FindBulkEndpoints(ctx->libusb, ctx->device_handle, &ctx->interface_number, &ctx->out_endpoint, &ctx->in_endpoint)) {
        return SDL_SetError("Couldn't find bulk endpoints");
    }

    ctx->libusb->set_auto_detach_kernel_driver(ctx->device_handle, true);
    int res = ctx->libusb->claim_interface(ctx->device_handle, ctx->interface_number);
    if (res < 0) {
        return SDL_SetError("Couldn't claim interface %d: %d\n", ctx->interface_number, res);
    }
    ctx->interface_claimed = true;
    return true;
}

// Transport-agnostic controller bring-up: flash reads for serial and
// calibration, then the init sequence. Runs over bulk endpoints (USB) or
// the 0x80/0x81 tunnel (virtual) through SendCommand/RecvResponse.
static bool HIDAPI_DriverSwitch2_InitController(SDL_HIDAPI_Device *device)
{
    SDL_DriverSwitch2_Context *ctx = (SDL_DriverSwitch2_Context *)device->context;
    int res;

    const Uint8 *init_sequence[] = {
        // ... lines 393–447 of the original, unchanged ...
    };

    unsigned char calibration_data[0x40] = {0};

    // ... lines 451–506 of the original, unchanged (ReadFlashBlock calls,
    //     GC trigger read, user-calibration reads, init loop) ...

    return true;
}

static bool HIDAPI_DriverSwitch2_InitUSB(SDL_HIDAPI_Device *device)
{
    if (!HIDAPI_DriverSwitch2_InitUSBTransport(device)) {
        return false;
    }
    return HIDAPI_DriverSwitch2_InitController(device);
}
```

Do the move with the editor, not by retyping: cut lines 392–506 into `InitController` unchanged. The only textual differences inside are the new `int res;` declaration at the top (the old code declared `res` in the transport section) and the function name.

- [ ] **Step 4: Add `InitVirtual` with the contract header**

Immediately after `HIDAPI_DriverSwitch2_InitUSB`, add:

```c
/* Virtual transport for software bridges (e.g. WaveBird on macOS).
 *
 * The bridge owns the physical link to the controller (Nintendo's custom
 * GATT over BLE, which no OS exposes as HID) and publishes a virtual HID
 * device that SDL drives exactly like the USB HID interface, plus a vendor
 * command tunnel replacing the USB bulk endpoints. Any bridge on any OS can
 * implement this contract:
 *
 *   Identity
 *     VID/PID       the controller's real IDs (0x057E / 0x2069 Pro,
 *                   0x2073 GameCube, 0x2067 Joy-Con L, 0x2066 Joy-Con R)
 *     Transport     virtual (SDL_HID_API_BUS_VIRTUAL)
 *
 *   Reports (vendor usage page 0xFF00 for the tunnel)
 *     0x05  Input   63 bytes  controller state, identical to USB Report 0x05
 *     0x09  Input   63 bytes  Pro only, declared for fidelity, never sent
 *     0x01/0x02/0x03  Output  63 bytes  native rumble (Joy-Con / Pro / GC),
 *                   written verbatim to the controller's vibration channel
 *     0x80  Output  64 bytes  command request: the frame this driver would
 *                   send over bulk, zero-padded. The bridge forwards the
 *                   first 8 + frame[5] bytes to the controller's command
 *                   channel, rewriting frame[2] for its transport
 *                   (0x00 = USB as sent here, 0x01 = Bluetooth).
 *     0x81  Input   80 bytes  command response frame, unmodified, zero-padded.
 *
 *   Rules
 *     - One command in flight per device; the bridge serialises.
 *     - The bridge answers within 1 s or not at all; this driver waits
 *       2 s (SWITCH2_VIRTUAL_RESPONSE_TIMEOUT_MS) and then treats the
 *       command as unanswered, like a short bulk read.
 *     - State reports keep flowing during a command; RecvResponse drops
 *       them while waiting, UpdateDevice drops stray 0x81 frames.
 *     - The bridge refuses command 0x15 (pairing key exchange). This
 *       driver never sends it.
 *     - The bridge has already initialised the controller for its own
 *       purposes before publishing the device; this driver's init sequence
 *       runs again through the tunnel and its settings win.
 */
static bool HIDAPI_DriverSwitch2_InitVirtual(SDL_HIDAPI_Device *device)
{
    return HIDAPI_DriverSwitch2_InitController(device);
}
```

- [ ] **Step 5: Branch in `InitDevice`**

Change lines 520–528 from:

```c
    if (device->is_bluetooth) {
        if (!HIDAPI_DriverSwitch2_InitBluetooth(device)) {
            return false;
        }
    } else {
        if (!HIDAPI_DriverSwitch2_InitUSB(device)) {
            return false;
        }
    }
```

to:

```c
    if (device->is_virtual) {
        if (!HIDAPI_DriverSwitch2_InitVirtual(device)) {
            return false;
        }
    } else if (device->is_bluetooth) {
        if (!HIDAPI_DriverSwitch2_InitBluetooth(device)) {
            return false;
        }
    } else {
        if (!HIDAPI_DriverSwitch2_InitUSB(device)) {
            return false;
        }
    }
```

- [ ] **Step 6: Skip late responses in `UpdateDevice`**

In `HIDAPI_DriverSwitch2_UpdateDevice`, after the `#endif` of the debug dump block and before `if (!joystick) { continue; }` (line 1270), add:

```c
        if (device->is_virtual && data[0] == SWITCH2_VIRTUAL_RESPONSE_REPORT_ID) {
            // A command reply that arrived after RecvResponse gave up; never state.
            continue;
        }
```

(`data` is `USB_PACKET_LENGTH` = 64 bytes; an 81-byte `0x81` report is truncated by the read, which is fine because it is discarded.)

- [ ] **Step 7: Confirm `FreeDevice` needs nothing**

`HIDAPI_DriverSwitch2_FreeDevice` already guards on `ctx->interface_claimed` and `ctx->libusb`, both false/NULL on the virtual path. No edit. Note it in the commit body.

- [ ] **Step 8: Build and install**

```bash
cmake --build /Users/joshua/Developer/SDL/build-mac && cmake --install /Users/joshua/Developer/SDL/build-mac
```

Expected: no warnings from `SDL_hidapi_switch2.c`; `install-mac/lib/libSDL3.dylib` updated (check `ls -l`).

- [ ] **Step 9: Smoke-run `testcontroller` with no controllers**

```bash
/Users/joshua/Developer/SDL/build-mac/test/testcontroller
```

Expected: window opens, no crash, "Waiting for controller…". Quit. (Real behaviour is validated in Task 3.)

- [ ] **Step 10: Commit**

```bash
cd /Users/joshua/Developer/SDL
git add src/joystick/hidapi/SDL_hidapi_switch2.c
git commit -m "hidapi: Switch 2 virtual transport over a HID command tunnel

Split InitUSB into the libusb transport setup and the transport-agnostic
controller init. On SDL_HID_API_BUS_VIRTUAL devices, commands go out as
Output Report 0x80 and replies come back as Input Report 0x81; state,
rumble and LED paths are unchanged. FreeDevice needs no change (libusb
guards already cover the virtual case). Contract documented on InitVirtual."
```

---

### Task 3: Hardware validation and upstream steps **[hardware]**

Requires WaveBird built in Debug with the relay plan's Tasks 1–6 applied and "NS2 Relay (SDL)" selected for the controller under test.

- [ ] **Step 1: Pro Controller** — run `build-mac/test/testcontroller`. Expect the device to enumerate as "Nintendo Switch Pro Controller", all buttons/sticks/triggers/hat mapped, gyro + accel live in the sensors view after ~1 s (the driver's 100-sample timestamp calibration), rumble on both bands from the test's rumble control, player LED set to slot 1.
- [ ] **Step 2: Init timing** — run with `SDL_LOGGING=input=debug` (or temporarily `#define DEBUG_SWITCH2_PROTOCOL`) and note that `InitController` completes; in WaveBird's stderr, confirm each `0x80` set-report is answered by an `0x81` dispatch, and the longest gap. Record the numbers in the PR text.
- [ ] **Step 3: GameCube** — analog L/R sweep the full trigger axis with correct rest position (trigger zeros from flash `0x13140` via the tunnel); single-motor rumble toggles.
- [ ] **Step 4: Joy-Con** — L alone and R alone show as mini controllers; with both relayed, SDL combines them into "Switch Joy-Con (L/R)" and both sticks and both rumble motors work.
- [ ] **Step 5: Reconnect** — power-cycle the controller mid-session; WaveBird republishes the VHID on reconnect; `testcontroller` sees a remove + add and the new instance initialises.
- [ ] **Step 6: `GCController` claim** — with relay active, run `swiftc -o /tmp/gcprobe /Users/joshua/Developer/WaveBird/Tools/GameControllerProbe.swift && /tmp/gcprobe` and note whether macOS claims the raw NS2 VID/PID. Nothing depends on the answer; record it.
- [ ] **Step 7: Open the upstream issue** — title "Switch 2 HIDAPI driver: virtual transport for software HID bridges". Body: the problem (BLE NS2 is never a HID device; CoreHID/uhid virtual devices are mis-detected as USB), the contract (paste the `InitVirtual` header), the enum-value question (ask the maintainer to pick; note `0x05` is a local placeholder), WaveBird as the shipping bridge, and the hardware results from Steps 1–5. Link the branch.
- [ ] **Step 8: PR after a maintainer reply** — rebase on `main`, adjust the enum value if asked, open the PR referencing the issue. Until it lands in a released SDL, WaveBird keeps `ns2Relay` DEBUG-only (see the WaveBird plan's Global Constraints).

---

## Self-review

**Spec coverage (§SDL design).**
- Bus type plumbing: public enum, vendored enum, mac both switches, Linux admit + map, `is_virtual` → Task 1. Combined Joy-Con bus type is an addition the spec doesn't list; it keeps `is_virtual` truthful on the parent and is called out as behaviour-neutral.
- Split `InitUSB` → Task 2 Step 3. Rename send/recv with virtual bodies (65-byte write, 81-byte read loop, 2000 ms, drop state, return 0 on timeout) → Task 2 Step 1. `InitDevice` branch → Step 5. `UpdateDevice` `0x81` skip, USB untouched → Step 6. `FreeDevice` no-op → Step 7. Rumble/LED/sensors unchanged → they call the renamed helpers or `hid_write`, covered by Step 2. Header comment on `InitVirtual` → Step 4.
- Upstream plan (issue → PR → DEBUG-only until release) → Task 3 Steps 7–8.
- Verification list → Task 3 Steps 1–6.

**Placeholder scan.** The one "…" in Task 2 Step 3 is an explicit instruction to move lines 392–506 verbatim (with the exact line range and the two textual differences named), not an omission. Everything else is complete code.

**Type consistency.** `SendCommand`/`RecvResponse` signatures match the old helpers so all ten call sites compile after a textual rename. `SWITCH2_VIRTUAL_RESPONSE_REPORT_ID` is defined in Step 1 and used in Step 6. `HIDAPI_DriverSwitch2_InitController` is defined in Step 3 and called from Step 3 (`InitUSB`) and Step 4 (`InitVirtual`). `is_virtual` is set in Task 1 and read in Task 2 Steps 1, 5, 6.

---

## Post-execution amendments (2026-09-10/11)

Implemented on SDL branch `switch2-virtual-transport` (commits `320ab9a27`, `d5ca73233`). Deviations from the text above, all from the whole-branch review or the hardware pass:

- Two files the plan never listed were required: the libusb whitelist exemption in `src/hidapi/SDL_hidapi.c` and the Windows `-Wswitch` case (now in File Structure and Global Constraints).
- Task 2 Step 1's `return SDL_SetError(...)` in `int SendCommand` returned 0 (success); it is `SDL_SetError(...); return -1;`.
- Virtual `RecvResponse` matches replies to the in-flight command by cmd ID (`report[1]`) and subcmd (`report[4]`), recorded on the context in `SendCommand`; the header's timing rule says the driver ignores non-matching replies.
- On the virtual path the first `RecvResponse` timeout in `ReadFlashBlock` or the init loop fails init. Parked: `InitController`'s flash-read callers only warn and continue, so a silent bridge still stalls ~16 s; one early return per call site remains to do before the upstream PR.
- `UpdateDevice` on the virtual path keeps only report `0x05` (allowlist) instead of skipping only `0x81`.
- Header rumble line: byte 0 becomes the `0x00` framing byte and the frame is trimmed to 42 bytes; not "verbatim".
- The five `SWITCH2_VIRTUAL_*` defines sit with the file's other defines near the top.
- Hardware (Task 3 Steps 1–5) passed 2026-09-11 on Pro, GameCube, and Joy-Con L/R via WaveBird `Tools/ns2_relay_probe.c`. The first attempt exposed a WaveBird-side deadlock (relay handler awaiting `dispatchInputReport` inside the CoreHID delegate), fixed in WaveBird `1ef3f94`. Steps 6–8 (GameController claim note, upstream issue, PR) remain.

