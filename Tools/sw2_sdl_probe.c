// sw2_sdl_probe — probe how SDL3 sees a Switch 2 Pro Controller exposed by
// WaveBird in NS2 Passthrough mode (or a real one over USB).
//
// Build:
//   brew install sdl3
//   clang -std=c11 -O0 -g -Wall -o sw2_sdl_probe \
//       Tools/sw2_sdl_probe.c \
//       -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3
//
// Run (with WaveBird publishing the Pro on ns2Passthrough):
//   ./sw2_sdl_probe
//
// What it does:
//   1. Initializes SDL_INIT_GAMEPAD and prints which SDL hidapi drivers are on.
//   2. Lists every joystick SDL sees, with VID/PID/name/GUID and whether SDL
//      classifies it as a gamepad (i.e. has a mapping).
//   3. Picks the first Switch-2-PID (0x057E:0x2069) device — falls back to the
//      first gamepad otherwise — and opens it.
//   4. Prints the SDL gamepad name, type, serial, and mapping string. Tries to
//      enable accel + gyro sensors and reports whether they actually turned on.
//   5. Drives one short low/high rumble pulse and a trigger-rumble pulse, then
//      releases (so a dropped run doesn't leave the controller buzzing).
//   6. Enters an event loop and prints button/axis/sensor changes until the
//      user hits Ctrl-C or presses HOME on the controller (or the OS-level
//      gamepad disconnects).
//
// SDL3 API surface used: SDL_GetJoysticks, SDL_OpenGamepad, SDL_GetGamepadType,
// SDL_GetGamepadMapping, SDL_RumbleGamepad, SDL_RumbleGamepadTriggers,
// SDL_SetGamepadSensorEnabled, SDL_GetGamepadSensorData, SDL_PollEvent.

#include <SDL3/SDL.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

static volatile sig_atomic_t g_should_quit = 0;
static void on_sigint(int sig) { (void)sig; g_should_quit = 1; }

static const char *gamepad_type_name(SDL_GamepadType t) {
    switch (t) {
    case SDL_GAMEPAD_TYPE_UNKNOWN:                       return "unknown";
    case SDL_GAMEPAD_TYPE_STANDARD:                      return "standard";
    case SDL_GAMEPAD_TYPE_XBOX360:                       return "xbox360";
    case SDL_GAMEPAD_TYPE_XBOXONE:                       return "xboxone";
    case SDL_GAMEPAD_TYPE_PS3:                           return "ps3";
    case SDL_GAMEPAD_TYPE_PS4:                           return "ps4";
    case SDL_GAMEPAD_TYPE_PS5:                           return "ps5";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO:           return "switch_pro";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT:   return "joycon_l";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT:  return "joycon_r";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR:   return "joycon_pair";
    default:                                             return "?";
    }
}

static const char *button_name(SDL_GamepadButton b) {
    const char *n = SDL_GetGamepadStringForButton(b);
    return n ? n : "?";
}

static const char *axis_name(SDL_GamepadAxis a) {
    const char *n = SDL_GetGamepadStringForAxis(a);
    return n ? n : "?";
}

// Print everything SDL has decided about the open gamepad — the things you'd
// otherwise have to dig out by hand. We dump the mapping too because that's the
// table SDL uses to route physical inputs to virtual buttons/axes; if it's
// missing or wrong, the event stream will look correspondingly broken.
static void dump_gamepad(SDL_Gamepad *gp) {
    SDL_JoystickID jid = SDL_GetGamepadID(gp);
    SDL_Joystick *js = SDL_GetGamepadJoystick(gp);

    printf("---- opened gamepad ----\n");
    printf("  joystick id  : %u\n", (unsigned)jid);
    printf("  name         : %s\n", SDL_GetGamepadName(gp));
    printf("  type         : %s (raw=%d)\n", gamepad_type_name(SDL_GetGamepadType(gp)),
           (int)SDL_GetGamepadType(gp));
    printf("  vendor:product: 0x%04X:0x%04X\n",
           (unsigned)SDL_GetGamepadVendor(gp),
           (unsigned)SDL_GetGamepadProduct(gp));
    const char *serial = SDL_GetGamepadSerial(gp);
    printf("  serial       : %s\n", serial ? serial : "(none)");
    char guid_buf[64];
    SDL_GUIDToString(SDL_GetJoystickGUID(js), guid_buf, sizeof(guid_buf));
    printf("  guid         : %s\n", guid_buf);
    char *mapping = SDL_GetGamepadMapping(gp);
    printf("  mapping      : %s\n", mapping ? mapping : "(none)");
    if (mapping) SDL_free(mapping);

    // Sensors: try to turn them on and read whether SDL actually has them. The
    // real Switch 2 Pro exposes accel + gyro; if SDL's mapping doesn't surface
    // them, SDL_GamepadHasSensor returns false even after SetEnabled.
    for (int s = SDL_SENSOR_ACCEL; s <= SDL_SENSOR_GYRO; s++) {
        SDL_SensorType st = (SDL_SensorType)s;
        bool present = SDL_GamepadHasSensor(gp, st);
        if (present) {
            bool ok = SDL_SetGamepadSensorEnabled(gp, st, true);
            bool enabled_after = SDL_GamepadSensorEnabled(gp, st);
            float rate = SDL_GetGamepadSensorDataRate(gp, st);
            printf("  sensor %s : present, enable=%s enabled=%s rate=%.1fHz\n",
                   st == SDL_SENSOR_ACCEL ? "accel" : "gyro ",
                   ok ? "ok" : "FAIL",
                   enabled_after ? "yes" : "no",
                   rate);
        } else {
            printf("  sensor %s : not present\n",
                   st == SDL_SENSOR_ACCEL ? "accel" : "gyro ");
        }
    }
    printf("------------------------\n");
    fflush(stdout);
}

static void list_joysticks(void) {
    int count = 0;
    SDL_JoystickID *ids = SDL_GetJoysticks(&count);
    printf("SDL sees %d joystick(s):\n", count);
    for (int i = 0; i < count; i++) {
        SDL_JoystickID id = ids[i];
        const char *name = SDL_GetJoystickNameForID(id);
        Uint16 vid = SDL_GetJoystickVendorForID(id);
        Uint16 pid = SDL_GetJoystickProductForID(id);
        bool is_gp = SDL_IsGamepad(id);
        char guid_buf[64];
        SDL_GUIDToString(SDL_GetJoystickGUIDForID(id), guid_buf, sizeof(guid_buf));
        printf("  [%d] id=%u %04X:%04X gamepad=%s guid=%s name=\"%s\"\n",
               i, (unsigned)id, (unsigned)vid, (unsigned)pid,
               is_gp ? "yes" : "no", guid_buf, name ? name : "(null)");
    }
    SDL_free(ids);
}

// Find the joystick most likely to be our Switch 2 Pro: VID/PID match first,
// then any gamepad. Returns 0 if nothing's connected.
static SDL_JoystickID pick_target(void) {
    int count = 0;
    SDL_JoystickID *ids = SDL_GetJoysticks(&count);
    SDL_JoystickID target = 0;
    for (int i = 0; i < count; i++) {
        SDL_JoystickID id = ids[i];
        Uint16 vid = SDL_GetJoystickVendorForID(id);
        Uint16 pid = SDL_GetJoystickProductForID(id);
        if (vid == 0x057E && pid == 0x2069) { target = id; break; }
    }
    if (!target) {
        for (int i = 0; i < count; i++) {
            if (SDL_IsGamepad(ids[i])) { target = ids[i]; break; }
        }
    }
    SDL_free(ids);
    return target;
}

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;
    signal(SIGINT, on_sigint);

    // Verbose log: every level on every category. SDL's hidapi backend logs
    // device match decisions here — invaluable for figuring out which driver
    // (Switch1 / Switch2 / generic HID) it picked for our virtual device.
    SDL_SetLogPriorities(SDL_LOG_PRIORITY_VERBOSE);

    // Force hidapi on (default) and explicitly enable the Switch backend.
    // SDL3 added a Switch2-specific driver; if it exists in this build, it'll
    // turn on with SDL_HINT_JOYSTICK_HIDAPI_SWITCH alongside the legacy one.
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_SWITCH, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_SWITCH_HOME_LED, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_GAMECUBE, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_JOY_CONS, "1");
    // Switch2 driver was added after the 3.4.8 release. The hint name is set
    // unconditionally — if the running dylib doesn't know it, it's silently
    // ignored. Required when running against SDL master (where the Switch2
    // driver gates on this hint, with default off).
    SDL_SetHint("SDL_JOYSTICK_HIDAPI_SWITCH2", "1");

    if (!SDL_Init(SDL_INIT_GAMEPAD | SDL_INIT_JOYSTICK | SDL_INIT_SENSOR)) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    printf("SDL revision: %s\n", SDL_GetRevision());
    printf("SDL version : %d\n", SDL_GetVersion());

    // Wait briefly for hidapi device enumeration. SDL's hidapi thread does the
    // initial scan on a worker, and joysticks can appear a few hundred ms after
    // SDL_Init returns. Pump events while we wait.
    Uint64 enum_deadline = SDL_GetTicks() + 1500;
    while (SDL_GetTicks() < enum_deadline) {
        SDL_PumpEvents();
        SDL_Delay(50);
    }

    list_joysticks();

    SDL_JoystickID target = pick_target();
    if (!target) {
        fprintf(stderr, "No joystick to open. Make sure WaveBird is running and the controller is on ns2Passthrough mode (or plug a real Switch 2 Pro in).\n");
        SDL_Quit();
        return 2;
    }

    SDL_Gamepad *gp = SDL_OpenGamepad(target);
    if (!gp) {
        // Not gamepad-recognized — fall back to raw joystick so we can still
        // see what SDL is doing with our virtual HID device.
        fprintf(stderr, "SDL_OpenGamepad failed: %s\n", SDL_GetError());
        SDL_Joystick *js = SDL_OpenJoystick(target);
        if (!js) {
            fprintf(stderr, "SDL_OpenJoystick failed too: %s\n", SDL_GetError());
            SDL_Quit();
            return 3;
        }
        printf("Opened as raw joystick: %s (axes=%d buttons=%d hats=%d)\n",
               SDL_GetJoystickName(js),
               SDL_GetNumJoystickAxes(js),
               SDL_GetNumJoystickButtons(js),
               SDL_GetNumJoystickHats(js));
        // Loop reading raw joystick state.
        while (!g_should_quit) {
            SDL_Event ev;
            while (SDL_PollEvent(&ev)) {
                switch (ev.type) {
                case SDL_EVENT_JOYSTICK_BUTTON_DOWN:
                case SDL_EVENT_JOYSTICK_BUTTON_UP:
                    printf("joy btn %d -> %s\n", ev.jbutton.button,
                           ev.jbutton.down ? "down" : "up");
                    fflush(stdout);
                    break;
                case SDL_EVENT_JOYSTICK_AXIS_MOTION:
                    if (ev.jaxis.value > 8000 || ev.jaxis.value < -8000) {
                        printf("joy axis %d -> %d\n", ev.jaxis.axis, ev.jaxis.value);
                        fflush(stdout);
                    }
                    break;
                case SDL_EVENT_JOYSTICK_REMOVED:
                    printf("joystick removed\n");
                    g_should_quit = 1;
                    break;
                default: break;
                }
            }
            SDL_Delay(10);
        }
        SDL_CloseJoystick(js);
        SDL_Quit();
        return 0;
    }

    dump_gamepad(gp);

    // Rumble probe. 800 ms low+high then 600 ms triggers, capped low so we
    // don't blow the controller's LRAs out for science. SDL_RumbleGamepad
    // returns false if the driver thinks rumble is unsupported — useful signal.
    printf("rumble: low/high pulse... ");
    fflush(stdout);
    bool r1 = SDL_RumbleGamepad(gp, 0x4000, 0x4000, 800);
    printf("%s\n", r1 ? "issued" : "UNSUPPORTED");
    SDL_Delay(900);
    printf("rumble: trigger pulse... ");
    fflush(stdout);
    bool r2 = SDL_RumbleGamepadTriggers(gp, 0x4000, 0x4000, 600);
    printf("%s\n", r2 ? "issued" : "UNSUPPORTED");
    SDL_Delay(700);
    SDL_RumbleGamepad(gp, 0, 0, 0);
    SDL_RumbleGamepadTriggers(gp, 0, 0, 0);

    printf("\nEntering event loop. Press buttons / move sticks. Ctrl-C or HOME to quit.\n");

    Uint64 last_sensor_print = 0;
    while (!g_should_quit) {
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            switch (ev.type) {
            case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
            case SDL_EVENT_GAMEPAD_BUTTON_UP: {
                SDL_GamepadButton b = (SDL_GamepadButton)ev.gbutton.button;
                printf("btn %-14s %s\n", button_name(b),
                       ev.gbutton.down ? "DOWN" : "up");
                fflush(stdout);
                if (b == SDL_GAMEPAD_BUTTON_GUIDE && ev.gbutton.down) {
                    g_should_quit = 1;
                }
                break;
            }
            case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
                // Throttle axes — sticks fire continuously while moved. Only
                // print when the value swings outside a deadzone so the log
                // stays readable.
                if (ev.gaxis.value > 8000 || ev.gaxis.value < -8000) {
                    SDL_GamepadAxis a = (SDL_GamepadAxis)ev.gaxis.axis;
                    printf("axis %-13s %d\n", axis_name(a), ev.gaxis.value);
                    fflush(stdout);
                }
                break;
            }
            case SDL_EVENT_GAMEPAD_SENSOR_UPDATE: {
                // Sensor data fires fast; sampled below from polling instead.
                break;
            }
            case SDL_EVENT_GAMEPAD_REMOVED: {
                printf("gamepad removed\n");
                g_should_quit = 1;
                break;
            }
            default: break;
            }
        }

        // Sample sensors at ~5 Hz so the console stays readable.
        Uint64 now = SDL_GetTicks();
        if (now - last_sensor_print > 200) {
            last_sensor_print = now;
            if (SDL_GamepadSensorEnabled(gp, SDL_SENSOR_GYRO)) {
                float g[3] = {0};
                if (SDL_GetGamepadSensorData(gp, SDL_SENSOR_GYRO, g, 3)) {
                    if (fabsf(g[0]) + fabsf(g[1]) + fabsf(g[2]) > 0.05f) {
                        printf("gyro  %+6.2f %+6.2f %+6.2f rad/s\n", g[0], g[1], g[2]);
                        fflush(stdout);
                    }
                }
            }
        }

        SDL_Delay(5);
    }

    SDL_RumbleGamepad(gp, 0, 0, 0);
    SDL_CloseGamepad(gp);
    SDL_Quit();
    return 0;
}
