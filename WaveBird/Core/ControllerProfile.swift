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
    func parseBLEReport(_ data: Data, calibration: StickCalibrationPair) -> ControllerState?
    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: StickCalibrationPair) -> ControllerState?

    // Map the controller's native shoulder/trigger buttons onto the "standard"
    // bumper + trigger roles that DS4/DualSense/Xbox/etc. all share. Spoof
    // output profiles rely on this so e.g. GC's ZL (digital top-left) lands on
    // L1, not L2 — even though both ZL and the Pro's L2-equivalent live in
    // the same ButtonSet slot for parsing convenience.
    func standardShoulders(_ state: ControllerState) -> StandardShoulders

    // Encode a normalized RumbleCommand into a BLE vibration payload for this
    // controller. Profiles inspect leftHD/rightHD (NS1 HD Rumble bytes) first
    // when present, falling back to leftAmp/rightAmp for output formats that
    // expose 8-bit motor values directly (e.g. Xbox USB report 0x09).
    // Returns nil if the controller has no motor or does not support rumble.
    func encodeRumble(_ cmd: RumbleCommand) -> Data?

    // Vendor passthrough descriptor: declares a single vendor input report
    // (usage page 0xFF00, report ID 0x05, 63 bytes) for ns2Passthrough mode.
    var vendorPassthroughDescriptor: Data { get }
}

extension ControllerProfile {
    func encodeRumble(_ cmd: RumbleCommand) -> Data? { nil }
}

// Normalized rumble command produced by HIDOutputSession.parseRumble. The
// coordinator routes one of these to ControllerProfile.encodeRumble per
// host-side Set Report, isolating each side from the other's wire format.
//
// leftHD/rightHD carry NS1-format HD Rumble bytes (4 bytes each: amplitude
// + frequency encoding). When non-nil they take priority. leftAmp/rightAmp
// are the fallback for output protocols that only expose 8-bit motor values.
// transmitCounter is used as the 4-bit tid in NS2 LRA state bytes so the
// controller doesn't dedupe successive commands; the coordinator refreshes
// it when re-sending a sustained command.
//
// refreshInterval is set by output sessions that produce one-shot commands
// targeting controllers with motor timeouts (e.g. Xbox sends start/stop ~1s
// apart while the NS2 motor expires after ~300 ms). The coordinator
// re-emits the command at this cadence until the next command arrives.
struct RumbleCommand: Sendable, Hashable {
    var leftAmp: UInt8 = 0
    var rightAmp: UInt8 = 0
    var leftHD: Data? = nil
    var rightHD: Data? = nil
    var transmitCounter: UInt8 = 0
    var refreshInterval: Duration? = nil

    var isStop: Bool {
        leftAmp == 0 && rightAmp == 0 && leftHD == nil && rightHD == nil
    }

    func withCounter(_ c: UInt8) -> Self {
        var copy = self
        copy.transmitCounter = c
        return copy
    }
}

// Cross-controller shoulder/trigger model. "Bumper" = top secondary, "trigger"
// = bottom primary. Analog values come from state.triggerL/R for controllers
// that have them (GC); for fully digital controllers (Pro) the analog field is
// 0 / 0xFF based on the digital press.
struct StandardShoulders: Sendable, Hashable {
    var leftBumper: Bool
    var rightBumper: Bool
    var leftTriggerDigital: Bool
    var rightTriggerDigital: Bool
    var leftTriggerAnalog: UInt8
    var rightTriggerAnalog: UInt8
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

struct StickCalibrationPair: Sendable, Equatable {
    var left: StickCalibration? = nil
    var right: StickCalibration? = nil
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
