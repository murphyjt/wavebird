@preconcurrency import CoreBluetooth
import Foundation

// Synthetic profile that represents an L+R Joy-Con 2 pair as a single virtual
// HID device. The pair coordinator hands an instance to the output catalog
// when it builds the merged VHID, so the output sessions (DS4/DualSense/
// Xbox/SwitchPro) drive the pair the same way they drive a Pro Controller.
// It is NOT registered as a BLE/USB profile — bleMatcher and usbMatcher are
// nil because Joy-Cons don't advertise under this PID.
//
// Identity: Pro Controller 2 (VID 0x057E, PID 0x2069). That's the closest
// first-class controller a host already recognizes, so games map the pair
// correctly without per-app config.
//
// Rumble routing is owned by the coordinator: it splits an incoming
// RumbleCommand into per-side single-motor commands and routes each to the
// matching JoyCon's vibration char. The pair profile's own encodeRumble is
// unused (returns nil) so a stray refresh against the pair won't mistakenly
// stream data anywhere.
struct JoyConPairProfile: ControllerProfile {
    let name = "Joy-Con 2 Pair"

    var bleMatcher: BLEMatcher? { nil }
    var usbMatcher: USBMatcher? { nil }

    // Pro Controller 2 IDs so existing host mappings (Switch Pro detection,
    // GameController.framework, browser Gamepad API) light up.
    let hidVendorID: UInt16 = 0x057E
    let hidProductID: UInt16 = 0x2069

    var vendorPassthroughDescriptor: Data { VirtualHIDDevice.ns2VendorDescriptor(reportID: 0x05, byteCount: 63) }

    func parseBLEReport(_ data: Data, calibration: ControllerCalibration) -> ControllerState? { nil }
    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: ControllerCalibration) -> ControllerState? { nil }

    func encodeRumble(_ cmd: RumbleCommand, sequence: UInt8, settings: RumbleSettings.Snapshot) -> Data? { nil }

    // True when a profile/PID combo belongs to one half of a Joy-Con pair.
    // The coordinator consults this both when handling .ready (defer VHID
    // until the partner arrives) and when forming the pair.
    static func isJoyCon(productID: UInt16) -> Bool {
        productID == 0x2067 || productID == 0x2066
    }
    static func isLeft(productID: UInt16) -> Bool { productID == 0x2067 }
    static func isRight(productID: UInt16) -> Bool { productID == 0x2066 }

    // Merge L + R state (either may be nil while one side is offline) into a
    // single ControllerState used by HID output sessions.
    static func merge(left: ControllerState?, right: ControllerState?) -> ControllerState {
        var merged = ControllerState.zero
        if let l = left {
            merged.leftStick = l.leftStick
            merged.buttons.formUnion(l.buttons)
            merged.shoulders.leftBumper = l.shoulders.leftBumper
            merged.shoulders.leftTriggerDigital = l.shoulders.leftTriggerDigital
            merged.shoulders.leftTriggerAnalog = l.shoulders.leftTriggerAnalog
            // Prefer L for IMU; R can override below if L's is missing.
            if let imu = l.imu { merged.imu = imu }
        }
        if let r = right {
            merged.rightStick = r.rightStick
            merged.buttons.formUnion(r.buttons)
            merged.shoulders.rightBumper = r.shoulders.rightBumper
            merged.shoulders.rightTriggerDigital = r.shoulders.rightTriggerDigital
            merged.shoulders.rightTriggerAnalog = r.shoulders.rightTriggerAnalog
            if merged.imu == nil, let imu = r.imu { merged.imu = imu }
        }
        merged.timestamp = .now
        return merged
    }
}
