// ns2_relay_probe — walk the NS2 relay hardware checklist against a patched SDL3.
//
// Exercises WaveBird's "NS2 Relay (SDL)" output mode end to end through the
// SDL branch `switch2-virtual-transport` (VIRTUAL bus type + the 0x80/0x81
// command tunnel in SDL_hidapi_switch2.c). Each step prints a [PASS]/[FAIL]
// line so a hardware run produces something you can paste into the upstream
// issue. Everything past step 0 needs a real controller relayed by WaveBird.
//
// Build (against the branch's own install prefix, not Homebrew SDL):
//   SDL=/Users/joshua/Developer/SDL
//   clang -std=c11 -Wall -Wextra -o /tmp/ns2_relay_probe Tools/ns2_relay_probe.c \
//       -I$SDL/install-mac/include -L$SDL/install-mac/lib -lSDL3 \
//       -Wl,-rpath,$SDL/install-mac/lib
//
// Run (WaveBird Debug build, controller on the relay profile):
//   /tmp/ns2_relay_probe [--verbose] [--quiet] [--no-combine]
//     --verbose     SDL_LOG_CATEGORY_INPUT at debug: shows SDL's own
//                   "Added HIDAPI device … bluetooth …" line and driver logs.
//     --quiet       checklist only; no per-event input lines.
//     --no-combine  keep Joy-Con L and R as two separate gamepads.
//
// Steps (numbered as in docs/superpowers/plans/2026-09-10-sdl-virtual-transport.md
// Task 3, roughly):
//   0. HID layer: SDL_hid_enumerate must list the relay device with bus type
//      VIRTUAL. This is the direct test of the bus-type plumbing and of the
//      libusb-only whitelist exemption — if the device is missing here, SDL
//      dropped it at enumeration and nothing downstream can work.
//   1. Init through the tunnel: time from the HID-layer sighting to
//      SDL_EVENT_GAMEPAD_ADDED (flash reads + init sequence over 0x80/0x81).
//      The serial only exists if flash 0x13000 was read through the tunnel.
//   2. State: button/axis/hat events until Ctrl-C. Buttons print SDL's
//      positional name (south/east/…, which SDL spells "a"/"b"/… in Xbox
//      order) and the controller's own label from SDL_GetGamepadButtonLabel,
//      so a Nintendo pad shows e.g. "east (B)" for its physical B button.
//   3. Rumble pulse (both bands), then a player-LED sweep: SDL player index
//      0..7 (the driver's eight 4-LED patterns), all off, back to slot 1. Each
//      step is one cmd 0x09/0x07 round trip through the tunnel.
//   4. Sensors: enable gyro + accel and count samples for 7 s (overlapping the sweep).
//   5. Reconnect: on removal, go back to waiting; the next add is checked as a
//      fresh instance (Step 1 identity again, rumble/sensor steps skipped).

#include <SDL3/SDL.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define NS2_VID 0x057E
#define MAX_PADS 4

static volatile sig_atomic_t g_should_quit = 0;
static void on_sigint(int sig) { (void)sig; g_should_quit = 1; }

static bool g_quiet = false;

// Step 1 timing: when the relay device was last seen at the HID layer with no
// gamepad open, and how long we give SDL to turn it into one. Consumed by the
// first GAMEPAD_ADDED so a second device (Joy-Con R after L) doesn't inherit it.
static Uint64 g_hid_seen_ticks = 0;
static Uint64 g_init_deadline = 0;
#define INIT_DEADLINE_MS 45000

// Step 5: set when an NS2 gamepad is removed; the next add is a reconnect.
static Uint64 g_removed_ticks = 0;
static SDL_JoystickID g_removed_id = 0;
static Uint16 g_removed_pid = 0;

static void hid_sighting(Uint64 now) {
    g_hid_seen_ticks = now;
    g_init_deadline = now + INIT_DEADLINE_MS;
}

// ---------------------------------------------------------------------------
// Small helpers

static const char *bus_name(SDL_hid_bus_type b) {
    switch (b) {
    case SDL_HID_API_BUS_UNKNOWN:   return "unknown";
    case SDL_HID_API_BUS_USB:       return "usb";
    case SDL_HID_API_BUS_BLUETOOTH: return "bluetooth";
    case SDL_HID_API_BUS_I2C:       return "i2c";
    case SDL_HID_API_BUS_SPI:       return "spi";
    case SDL_HID_API_BUS_VIRTUAL:   return "VIRTUAL";
    default:                        return "?";
    }
}

static const char *ns2_product_name(Uint16 pid) {
    switch (pid) {
    case 0x2069: return "Pro Controller";
    case 0x2073: return "GameCube Controller";
    case 0x2067: return "Joy-Con (L)";
    case 0x2066: return "Joy-Con (R)";
    case 0x2068: return "Joy-Con pair (SDL combined)";
    default:     return NULL;
    }
}

static bool is_ns2(Uint16 vid, Uint16 pid) {
    return vid == NS2_VID && ns2_product_name(pid) != NULL;
}

static const char *gamepad_type_name(SDL_GamepadType t) {
    switch (t) {
    case SDL_GAMEPAD_TYPE_UNKNOWN:                      return "unknown";
    case SDL_GAMEPAD_TYPE_STANDARD:                     return "standard";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO:          return "switch_pro";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT:  return "joycon_l";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT: return "joycon_r";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR:  return "joycon_pair";
    case SDL_GAMEPAD_TYPE_GAMECUBE:                     return "gamecube";
    default:                                            return "other";
    }
}

static const char *connection_name(SDL_JoystickConnectionState s) {
    switch (s) {
    case SDL_JOYSTICK_CONNECTION_WIRED:    return "wired";
    case SDL_JOYSTICK_CONNECTION_WIRELESS: return "wireless";
    case SDL_JOYSTICK_CONNECTION_UNKNOWN:  return "unknown";
    default:                               return "invalid";
    }
}

static void check(bool ok, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("  [%s] ", ok ? "PASS" : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    fflush(stdout);
}

static void note(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("         ");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    fflush(stdout);
}

// ---------------------------------------------------------------------------
// Step 0 — HID layer

// Returns the number of NS2 devices SDL's hidapi layer reports on the VIRTUAL
// bus. Prints every NS2 device it sees regardless of bus so a wrong bus type
// (e.g. the pre-patch "usb" misdetection) is visible.
static int hid_layer_scan(bool print) {
    int virtual_count = 0;
    int ns2_count = 0;
    SDL_hid_device_info *devs = SDL_hid_enumerate(NS2_VID, 0);
    for (SDL_hid_device_info *d = devs; d; d = d->next) {
        if (!is_ns2(d->vendor_id, d->product_id)) {
            continue;
        }
        ns2_count++;
        if (d->bus_type == SDL_HID_API_BUS_VIRTUAL) {
            virtual_count++;
        }
        if (print) {
            printf("    %04X:%04X %-20s bus=%-9s usage=%04X:%04X iface=%d product=\"%ls\" path=%s\n",
                   d->vendor_id, d->product_id, ns2_product_name(d->product_id),
                   bus_name(d->bus_type), d->usage_page, d->usage, d->interface_number,
                   d->product_string ? d->product_string : L"",
                   d->path ? d->path : "");
        }
    }
    SDL_hid_free_enumeration(devs);
    if (print) {
        if (ns2_count == 0) {
            note("no NS2 device at the HID layer. If WaveBird is publishing, SDL dropped it at");
            note("enumeration: check the libusb-only whitelist exemption in src/hidapi/SDL_hidapi.c");
            note("(SDL_HIDAPI_ShouldIgnoreDevice) and that the VHID reports Transport = \"Virtual\".");
        }
    }
    return virtual_count;
}

// ---------------------------------------------------------------------------
// Per-gamepad state

typedef struct {
    SDL_Gamepad *gp;
    SDL_JoystickID id;
    Uint16 pid;
    Sint16 last_axis[SDL_GAMEPAD_AXIS_COUNT];
    int accel_samples;
    int gyro_samples;
    Uint64 sensor_window_end;   // SDL_GetTicks() deadline for the sensor count
    bool sensor_reported;
    bool rumble_active;
    Uint64 rumble_stop_at;
    bool led_sweeping;
    int led_step;               // 0..7 player index, 8 = all off, 9 = restore slot 1
    Uint64 led_next_at;
} Pad;

static Pad g_pads[MAX_PADS];

static Pad *pad_for(SDL_JoystickID id) {
    for (int i = 0; i < MAX_PADS; i++) {
        if (g_pads[i].gp && g_pads[i].id == id) {
            return &g_pads[i];
        }
    }
    return NULL;
}

static Pad *free_slot(void) {
    for (int i = 0; i < MAX_PADS; i++) {
        if (!g_pads[i].gp) {
            return &g_pads[i];
        }
    }
    return NULL;
}

static int open_pad_count(void) {
    int n = 0;
    for (int i = 0; i < MAX_PADS; i++) {
        if (g_pads[i].gp) n++;
    }
    return n;
}

static void list_joysticks(void) {
    int count = 0;
    SDL_JoystickID *ids = SDL_GetJoysticks(&count);
    printf("    SDL joystick list (%d):\n", count);
    for (int i = 0; i < count; i++) {
        char guid[64];
        SDL_GUIDToString(SDL_GetJoystickGUIDForID(ids[i]), guid, sizeof(guid));
        const char *name = SDL_GetJoystickNameForID(ids[i]);
        printf("      id=%u %04X:%04X gamepad=%s guid=%s \"%s\"\n",
               (unsigned)ids[i],
               SDL_GetJoystickVendorForID(ids[i]), SDL_GetJoystickProductForID(ids[i]),
               SDL_IsGamepad(ids[i]) ? "yes" : "no", guid, name ? name : "(null)");
    }
    SDL_free(ids);
}

// ---------------------------------------------------------------------------
// Steps 1, 3, 4 — run once per gamepad add

static void step1_identity(Pad *p, Uint64 hid_seen_ticks, Uint64 added_ticks) {
    SDL_Gamepad *gp = p->gp;
    SDL_Joystick *js = SDL_GetGamepadJoystick(gp);
    const char *serial = SDL_GetGamepadSerial(gp);
    SDL_GamepadType type = SDL_GetGamepadType(gp);
    SDL_JoystickConnectionState conn = SDL_GetGamepadConnectionState(gp);
    char guid[64];
    SDL_GUIDToString(SDL_GetJoystickGUID(js), guid, sizeof(guid));

    printf("\n== Step 1: init through the tunnel — %s (id=%u)\n",
           ns2_product_name(p->pid), (unsigned)p->id);
    if (hid_seen_ticks) {
        note("HID-layer sighting -> GAMEPAD_ADDED: %llu ms (upper bound; includes SDL's own",
             (unsigned long long)(added_ticks - hid_seen_ticks));
        note("hotplug latency; ~19 tunnel round-trips of flash reads + init sequence)");
    } else {
        note("no HID-layer sighting captured before SDL added it; init time not measured");
    }
    note("name=\"%s\" type=%s conn=%s firmware=0x%04X guid=%s",
         SDL_GetGamepadName(gp), gamepad_type_name(type), connection_name(conn),
         SDL_GetGamepadFirmwareVersion(gp), guid);
    check(type == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO ||
          type == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT ||
          type == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT ||
          type == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR ||
          type == SDL_GAMEPAD_TYPE_GAMECUBE,
          "SDL classified it as a Switch-family gamepad (%s)", gamepad_type_name(type));
    check(serial && serial[0],
          "serial from flash 0x13000 via tunnel: %s", serial && serial[0] ? serial : "(none)");
    note("connection state \"%s\" — the review expects \"wired\" for a virtual bus", connection_name(conn));
    note("axes=%d buttons=%d hats=%d",
         SDL_GetNumJoystickAxes(js), SDL_GetNumJoystickButtons(js), SDL_GetNumJoystickHats(js));
    list_joysticks();
}

static void step3_rumble_and_led(Pad *p) {
    printf("\n== Step 3: rumble + player LED — %s\n", ns2_product_name(p->pid));
    bool r = SDL_RumbleGamepad(p->gp, 0x8000, 0x8000, 500);
    check(r, "SDL_RumbleGamepad(0x8000, 0x8000, 500 ms) accepted%s%s",
          r ? "" : ": ", r ? "" : SDL_GetError());
    if (p->pid == 0x2073) {
        note("GameCube has a single on/off motor; expect one buzz, not two bands");
    }
    p->rumble_active = r;
    p->rumble_stop_at = SDL_GetTicks() + 600;

    note("LED sweep: player index 0..7, then off, then back to slot 1 (~600 ms each)");
    p->led_sweeping = true;
    p->led_step = 0;
    p->led_next_at = SDL_GetTicks();
}

// One step of the LED sweep. Patterns mirror UpdateSlotLED's player_pattern[]
// in SDL_hidapi_switch2.c; bit 0 is the leftmost LED.
static void led_sweep_step(Pad *p) {
    static const Uint8 pattern[8] = { 0x1, 0x3, 0x7, 0xf, 0x9, 0x5, 0xd, 0x6 };
    int index;
    Uint8 mask;
    const char *what;
    if (p->led_step < 8) {
        index = p->led_step;
        mask = pattern[index];
        what = "player index";
    } else if (p->led_step == 8) {
        index = -1;
        mask = 0;
        what = "all off (index";
    } else {
        index = 0;
        mask = pattern[0];
        what = "restore slot 1 (index";
    }
    char glyph[5];
    for (int i = 0; i < 4; i++) {
        glyph[i] = (mask & (1 << i)) ? '*' : '.';
    }
    glyph[4] = '\0';
    bool ok = SDL_SetGamepadPlayerIndex(p->gp, index);
    check(ok, "%s %d%s -> LEDs %s (0x%X)%s%s", what, index,
          p->led_step >= 8 ? ")" : "", glyph, mask,
          ok ? "" : ": ", ok ? "" : SDL_GetError());
    p->led_step++;
    if (p->led_step > 9) {
        p->led_sweeping = false;
        note("LED sweep done; controller should show slot 1");
    } else {
        p->led_next_at = SDL_GetTicks() + 600;
    }
}

static void step4_sensors_begin(Pad *p) {
    printf("\n== Step 4: sensors — %s\n", ns2_product_name(p->pid));
    for (int s = SDL_SENSOR_ACCEL; s <= SDL_SENSOR_GYRO; s++) {
        SDL_SensorType st = (SDL_SensorType)s;
        const char *label = st == SDL_SENSOR_ACCEL ? "accel" : "gyro";
        if (!SDL_GamepadHasSensor(p->gp, st)) {
            check(false, "%s present", label);
            continue;
        }
        bool ok = SDL_SetGamepadSensorEnabled(p->gp, st, true);
        check(ok && SDL_GamepadSensorEnabled(p->gp, st),
              "%s enabled (rate %.0f Hz)", label, SDL_GetGamepadSensorDataRate(p->gp, st));
    }
    if (p->pid == 0x2073) {
        note("GameCube reports no IMU; sensor checks above are expected to be absent");
    }
    p->accel_samples = 0;
    p->gyro_samples = 0;
    p->sensor_reported = false;
    // The driver needs ~100 samples to calibrate its timestamp base before it
    // reports anything; give it that plus a margin.
    p->sensor_window_end = SDL_GetTicks() + 7000;
    note("counting sensor samples for 7 s (driver calibrates on the first ~100; overlaps the LED sweep)…");
}

static void step2_banner(bool after_reconnect) {
    printf("\n== Step 2: state — move sticks, press buttons. Ctrl-C exits.\n");
    if (!after_reconnect) {
        printf("   Power-cycle the controller to exercise Step 5 (reconnect).\n");
    }
    fflush(stdout);
}

static void step4_sensors_finish(Pad *p) {
    bool has_imu = SDL_GamepadHasSensor(p->gp, SDL_SENSOR_GYRO) ||
                   SDL_GamepadHasSensor(p->gp, SDL_SENSOR_ACCEL);
    if (has_imu) {
        check(p->accel_samples > 0, "accel samples in window: %d", p->accel_samples);
        check(p->gyro_samples > 0, "gyro samples in window: %d", p->gyro_samples);
    }
    step2_banner(false);
    p->sensor_reported = true;
}

static void on_gamepad_added(SDL_JoystickID id) {
    Uint16 vid = SDL_GetGamepadVendorForID(id);
    Uint16 pid = SDL_GetGamepadProductForID(id);
    if (!is_ns2(vid, pid)) {
        note("ignoring non-NS2 gamepad id=%u %04X:%04X \"%s\"",
             (unsigned)id, vid, pid, SDL_GetGamepadNameForID(id));
        return;
    }
    Pad *p = free_slot();
    if (!p) {
        note("no free slot for id=%u", (unsigned)id);
        return;
    }
    Uint64 added = SDL_GetTicks();
    Uint64 hid_seen_ticks = g_hid_seen_ticks;
    g_hid_seen_ticks = 0;
    g_init_deadline = 0;
    SDL_Gamepad *gp = SDL_OpenGamepad(id);
    check(gp != NULL, "SDL_OpenGamepad(id=%u)%s%s", (unsigned)id,
          gp ? "" : ": ", gp ? "" : SDL_GetError());
    if (!gp) {
        return;
    }
    memset(p, 0, sizeof(*p));
    p->gp = gp;
    p->id = id;
    p->pid = pid;

    if (g_removed_ticks) {
        printf("\n== Step 5: reconnect — %s\n", ns2_product_name(pid));
        check(pid == g_removed_pid,
              "same product came back (%04X) as a new instance: id=%u -> id=%u, %llu ms after removal",
              pid, (unsigned)g_removed_id, (unsigned)id,
              (unsigned long long)(added - g_removed_ticks));
        g_removed_ticks = 0;
        step1_identity(p, hid_seen_ticks, added);
        note("rumble/LED/sensor steps skipped on reconnect (validated on the first add)");
        p->sensor_reported = true;   // no sensor window on a reconnect
        step2_banner(true);
        return;
    }

    step1_identity(p, hid_seen_ticks, added);
    step3_rumble_and_led(p);
    step4_sensors_begin(p);
}

static void close_pad(Pad *p) {
    if (!p->gp) return;
    SDL_RumbleGamepad(p->gp, 0, 0, 0);
    SDL_CloseGamepad(p->gp);
    memset(p, 0, sizeof(*p));
}

// ---------------------------------------------------------------------------
// Event handling

static const char *button_name(SDL_GamepadButton b) {
    const char *n = SDL_GetGamepadStringForButton(b);
    return n ? n : "?";
}

// SDL's button names are positional (south/east/west/north, spelled a/b/x/y
// in Xbox order); the label is what is printed on this controller's cap.
static const char *button_label(SDL_Gamepad *gp, SDL_GamepadButton b) {
    switch (SDL_GetGamepadButtonLabel(gp, b)) {
    case SDL_GAMEPAD_BUTTON_LABEL_A:        return "A";
    case SDL_GAMEPAD_BUTTON_LABEL_B:        return "B";
    case SDL_GAMEPAD_BUTTON_LABEL_X:        return "X";
    case SDL_GAMEPAD_BUTTON_LABEL_Y:        return "Y";
    case SDL_GAMEPAD_BUTTON_LABEL_CROSS:    return "Cross";
    case SDL_GAMEPAD_BUTTON_LABEL_CIRCLE:   return "Circle";
    case SDL_GAMEPAD_BUTTON_LABEL_SQUARE:   return "Square";
    case SDL_GAMEPAD_BUTTON_LABEL_TRIANGLE: return "Triangle";
    default:                                return NULL;
    }
}

static const char *axis_name(SDL_GamepadAxis a) {
    const char *n = SDL_GetGamepadStringForAxis(a);
    return n ? n : "?";
}

// Returns false when the user asked to quit.
static bool handle_event(const SDL_Event *e) {
    switch (e->type) {
    case SDL_EVENT_GAMEPAD_ADDED:
        on_gamepad_added(e->gdevice.which);
        break;

    case SDL_EVENT_GAMEPAD_REMOVED: {
        Pad *p = pad_for(e->gdevice.which);
        if (p) {
            printf("\n   %s removed (id=%u). Power it back on; the next add is Step 5.\n",
                   ns2_product_name(p->pid), (unsigned)p->id);
            fflush(stdout);
            g_removed_ticks = SDL_GetTicks();
            g_removed_id = p->id;
            g_removed_pid = p->pid;
            close_pad(p);
        }
        break;
    }

    case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
    case SDL_EVENT_GAMEPAD_BUTTON_UP: {
        Pad *p = pad_for(e->gbutton.which);
        if (!p) break;
        if (!g_quiet) {
            SDL_GamepadButton b = (SDL_GamepadButton)e->gbutton.button;
            const char *label = button_label(p->gp, b);
            char shown[32];
            if (label) {
                SDL_snprintf(shown, sizeof(shown), "%s (%s)", button_name(b), label);
            } else {
                SDL_snprintf(shown, sizeof(shown), "%s", button_name(b));
            }
            printf("  [id=%u] button %-18s %s\n", (unsigned)p->id, shown,
                   e->gbutton.down ? "down" : "up");
        }
        break;
    }

    case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
        Pad *p = pad_for(e->gaxis.which);
        if (!p || g_quiet) break;
        int a = e->gaxis.axis;
        if (a < 0 || a >= SDL_GAMEPAD_AXIS_COUNT) break;
        // Only print meaningful movement; a 12-bit stick relayed at ~70 Hz
        // otherwise floods the terminal.
        int delta = (int)e->gaxis.value - (int)p->last_axis[a];
        if (delta > 1500 || delta < -1500 ||
            (e->gaxis.value == 0 && p->last_axis[a] != 0)) {
            p->last_axis[a] = e->gaxis.value;
            printf("  [id=%u] axis   %-14s %6d\n", (unsigned)p->id,
                   axis_name((SDL_GamepadAxis)a), (int)e->gaxis.value);
        }
        break;
    }

    case SDL_EVENT_GAMEPAD_SENSOR_UPDATE: {
        Pad *p = pad_for(e->gsensor.which);
        if (!p) break;
        if (e->gsensor.sensor == SDL_SENSOR_ACCEL) {
            if (p->accel_samples++ == 0) {
                note("first accel sample: %.3f %.3f %.3f (m/s^2)",
                     e->gsensor.data[0], e->gsensor.data[1], e->gsensor.data[2]);
            }
        } else if (e->gsensor.sensor == SDL_SENSOR_GYRO) {
            if (p->gyro_samples++ == 0) {
                note("first gyro sample: %.3f %.3f %.3f (rad/s)",
                     e->gsensor.data[0], e->gsensor.data[1], e->gsensor.data[2]);
            }
        }
        break;
    }

    default:
        break;
    }
    return true;
}

// Timed work that doesn't come from events: rumble stop, sensor window end.
static void tick_pads(void) {
    Uint64 now = SDL_GetTicks();
    for (int i = 0; i < MAX_PADS; i++) {
        Pad *p = &g_pads[i];
        if (!p->gp) continue;
        if (p->rumble_active && now >= p->rumble_stop_at) {
            SDL_RumbleGamepad(p->gp, 0, 0, 0);
            p->rumble_active = false;
        }
        if (p->led_sweeping && now >= p->led_next_at) {
            led_sweep_step(p);
        }
        if (!p->sensor_reported && now >= p->sensor_window_end) {
            step4_sensors_finish(p);
        }
    }
}

// ---------------------------------------------------------------------------

int main(int argc, char *argv[]) {
    bool verbose = false;
    bool combine = true;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--verbose") == 0) verbose = true;
        else if (strcmp(argv[i], "--quiet") == 0) g_quiet = true;
        else if (strcmp(argv[i], "--no-combine") == 0) combine = false;
        else {
            fprintf(stderr, "usage: %s [--verbose] [--quiet] [--no-combine]\n", argv[0]);
            return 2;
        }
    }
    signal(SIGINT, on_sigint);

    if (verbose) {
        SDL_SetLogPriority(SDL_LOG_CATEGORY_INPUT, SDL_LOG_PRIORITY_DEBUG);
    }

    // Step 0 runs before the joystick subsystem so the listing reflects what
    // hidapi alone reports, not what a driver already claimed.
    printf("== Step 0: HID layer (SDL_hid_enumerate 057E:*)\n");
    if (SDL_hid_init() != 0) {
        fprintf(stderr, "SDL_hid_init failed: %s\n", SDL_GetError());
        return 1;
    }
    int virt = hid_layer_scan(true);
    check(virt > 0, "%d NS2 device(s) on the VIRTUAL bus", virt);
    if (virt > 0) {
        hid_sighting(SDL_GetTicks());
    }

    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_SWITCH2, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_COMBINE_JOY_CONS, combine ? "1" : "0");

    if (!SDL_Init(SDL_INIT_GAMEPAD | SDL_INIT_JOYSTICK)) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    printf("\nSDL %d.%d.%d, hidapi Switch2 driver on, Joy-Con combine %s\n",
           SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_MICRO_VERSION, combine ? "on" : "off");
    printf("Waiting for a relayed controller (Ctrl-C to quit)…\n");
    fflush(stdout);

    // Poll the HID layer while nothing is open so a hotplug gets a sighting
    // timestamp, and so a device that never reaches GAMEPAD_ADDED is reported
    // as an init failure instead of silence.
    Uint64 next_scan = 0;
    bool running = true;
    while (running && !g_should_quit) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_EVENT_QUIT) { running = false; break; }
            if (!handle_event(&e)) { running = false; break; }
        }
        tick_pads();

        Uint64 now = SDL_GetTicks();
        if (open_pad_count() == 0 && now >= next_scan) {
            next_scan = now + 250;
            int v = hid_layer_scan(false);
            if (v > 0 && g_hid_seen_ticks == 0) {
                hid_sighting(now);
                printf("  HID layer: relay device appeared; waiting for SDL to init it…\n");
                fflush(stdout);
            } else if (v == 0 && g_hid_seen_ticks != 0) {
                g_hid_seen_ticks = 0;
                g_init_deadline = 0;
            }
            if (g_init_deadline && now >= g_init_deadline) {
                check(false, "device visible at the HID layer for %d s but never became a gamepad",
                      INIT_DEADLINE_MS / 1000);
                note("SDL's init through the tunnel failed. Re-run with --verbose and check");
                note("WaveBird's stderr for each 0x80 set-report and its 0x81 reply.");
                g_init_deadline = 0;
            }
        }
        SDL_Delay(5);
    }

    for (int i = 0; i < MAX_PADS; i++) {
        close_pad(&g_pads[i]);
    }
    SDL_Quit();
    SDL_hid_exit();
    return 0;
}
