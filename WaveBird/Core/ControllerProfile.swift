@preconcurrency import CoreBluetooth
import Foundation

protocol ControllerProfile: Sendable {
    var name: String { get }
    var bleMatcher: BLEMatcher? { get }
    var usbMatcher: USBMatcher? { get }

    var hidDescriptor: Data { get }
    var hidVendorID: UInt16 { get }
    var hidProductID: UInt16 { get }

    func buildHIDReport(_ state: ControllerState) -> Data
    func parseBLEReport(_ data: Data, calibration: ControllerCalibration) -> ControllerState?
    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: ControllerCalibration) -> ControllerState?

    // Encode a normalized RumbleCommand into a BLE vibration payload for this
    // controller. `sequence` is a coordinator-managed counter the encoder folds
    // into protocol-specific dedupe fields (NS2 LRA tid nibble). `settings` is
    // the device's RumbleSettings snapshot — profiles that don't expose tunable
    // rumble (e.g. GameCube's on/off) ignore it. Returns nil if the controller
    // has no motor or does not support rumble.
    func encodeRumble(_ cmd: RumbleCommand, sequence: UInt8, settings: RumbleSettings.Snapshot) -> Data?

    // Minimum re-send cadence the controller wants for a sustained rumble
    // command. The coordinator runs the refresh task at the MIN of this and the
    // active HIDOutputSession's refreshInterval — whichever is more frequent
    // wins. nil = no controller-side requirement (use the session's value).
    var rumbleRefreshInterval: Duration? { get }

    // Vendor passthrough descriptor: declares a single vendor input report
    // (usage page 0xFF00, report ID 0x05, 63 bytes) for ns2Passthrough mode.
    var vendorPassthroughDescriptor: Data { get }

    // Parse a BLE command response into structured device metadata. The
    // default implementation handles the addresses common to every NS2
    // controller (serial / firmware / stick calibration); profiles override
    // to add controller-specific reads (e.g. GC trigger zeros at 0x13140).
    func handleCommandResponse(request: Data, response: Data) -> ControllerMetadata?
}

extension ControllerProfile {
    func encodeRumble(_ cmd: RumbleCommand, sequence: UInt8, settings: RumbleSettings.Snapshot) -> Data? { nil }

    var rumbleRefreshInterval: Duration? { nil }

    func handleCommandResponse(request: Data, response: Data) -> ControllerMetadata? {
        NS2Responses.parseStandard(request: request, response: response)
    }
}

// Structured fields extracted from a controller's BLE command responses.
// Returned by ControllerProfile.handleCommandResponse; the coordinator merges
// any non-nil field into the device record without knowing what produced it.
struct ControllerMetadata: Sendable {
    var serial: String? = nil
    var firmware: FirmwareInfo? = nil
    var triggerZeros: TriggerZeros? = nil
    var leftCalibration: StickCalibration? = nil
    var rightCalibration: StickCalibration? = nil
    // 0–2 host BT addresses (natural order) that this controller's pairing
    // block at flash 0x1FA000 currently holds. nil means "we haven't read it
    // yet" (different from "we read it and it was empty" which is []).
    var onDeviceHostAddresses: [Data]? = nil
}

// Normalized rumble command produced by HIDOutputSession.parseRumble. The
// coordinator routes one of these to ControllerProfile.encodeRumble per
// host-side Set Report, isolating each side from the other's wire format.
//
// Amplitudes are 16-bit because that's the precision the upstream protocols
// produce: SDL/Apple/Linux all pass UInt16 motor amplitudes (0..65535) into
// their rumble encoders, and the SwitchPro spoof reverses NS1 HD Rumble
// bytes back through dekuNukem's amplitude lookup table to recover the
// original value. 8-bit-source protocols (DS4/DualSense) scale up by 257.
struct RumbleCommand: Sendable, Hashable {
    var leftAmp: UInt16 = 0
    var rightAmp: UInt16 = 0
    // Per-side carrier overrides used by test patterns to play melodic
    // sequences (e.g. the GameCube boot chime). nil = use whatever the user's
    // RumbleSettings has dialed in. The encoder applies the override to BOTH
    // HF and LF bands of that side so the perceived pitch shifts cleanly.
    var leftFreqOverride: UInt16? = nil
    var rightFreqOverride: UInt16? = nil

    var isStop: Bool { leftAmp == 0 && rightAmp == 0 }
}

// Cross-controller shoulder/trigger model. "Bumper" = top secondary, "trigger"
// = bottom primary. Analog values come from state.triggerL/R for controllers
// that have them (GC); for fully digital controllers (Pro) the analog field is
// 0 / 0xFF based on the digital press.
struct StandardShoulders: Sendable, Hashable {
    var leftBumper: Bool = false
    var rightBumper: Bool = false
    var leftTriggerDigital: Bool = false
    var rightTriggerDigital: Bool = false
    var leftTriggerAnalog: UInt8 = 0
    var rightTriggerAnalog: UInt8 = 0
}

// Per-axis stick calibration extracted from controller flash. All values are in the
// raw 12-bit ADC space. `max` is the deflection above `neutral`, `min` is below.
struct StickCalibration: Sendable, Equatable {
    var neutralX: UInt16
    var neutralY: UInt16
    var maxX: UInt16
    var maxY: UInt16
    var minX: UInt16
    var minY: UInt16
}

// Per-device calibration aggregate populated from the BLE init handshake
// responses. Profiles consume it inside their parsers (stick mapping uses
// left/right; GC applies triggerZeros to the raw trigger axes). Keep this as
// a single bag so parser signatures stay stable as new calibration kinds
// land (e.g. IMU offsets, JoyCon SR/SL).
struct ControllerCalibration: Sendable, Equatable {
    var left: StickCalibration? = nil
    var right: StickCalibration? = nil
    var triggerZeros: TriggerZeros? = nil
}

struct TriggerZeros: Sendable, Equatable {
    var left: UInt8
    var right: UInt8
}

struct BLEMatcher: Sendable {
    let productID: UInt16
    let serviceUUID: CBUUID
    let inputCharacteristic: CBUUID
    let outputCharacteristic: CBUUID?
    let responseCharacteristics: [ResponseChannel]
    let initCommands: [Data]
    let vibrationCharacteristic: CBUUID?
}

struct ResponseChannel: Sendable {
    let uuid: CBUUID
    let handle: UInt16
}

struct USBMatcher: Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let initWrites: [USBInitStep]
}

struct USBInitStep: Sendable {
    let reportID: UInt8
    let payload: Data
}

enum TransportMatcher: Sendable {
    case ble(BLEMatcher)
    case usb(USBMatcher)
}
