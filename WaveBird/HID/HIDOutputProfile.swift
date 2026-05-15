import CoreHID
import Foundation

// HIDOutputProfile is the identity card for the virtual HID device we present
// to macOS — its VID/PID, descriptor, and product strings. It does NOT build
// reports; that's the session's job. The split lets stateful spoofs (e.g.
// Switch Pro, which emulates Nintendo's subcommand handshake) share the same
// dispatch path as stateless ones.
//
// The default `.native` mode delegates to the connected controller's own
// ControllerProfile (so the GC controller reports as a GC controller, the Pro
// as a Pro). The other modes spoof a well-known third-party controller that
// GameController.framework, web Gamepad API, and most games already have
// built-in mappings for.
//
// Spoofs map shoulders/triggers via ControllerProfile.standardShoulders so
// GC's ZL/Z (digital top) land on the bumpers and L/R (analog clicks) land on
// the triggers — physically correct for each controller despite ButtonSet's
// Nintendo-flavored naming.

enum HIDOutputMode: String, CaseIterable, Sendable, Hashable {
    case native
    case switchPro
    case dualShock4
    case dualSense
    case xboxSeries

    var displayName: String {
        switch self {
        case .native:      return "Native (Switch 2)"
        case .switchPro:   return "Switch Pro Controller"
        case .dualShock4:  return "DualShock 4"
        case .dualSense:   return "DualSense"
        case .xboxSeries:  return "Xbox Wireless Controller"
        }
    }
}

protocol HIDOutputProfile: Sendable {
    var vendorID: UInt16 { get }
    var productID: UInt16 { get }
    var productName: String { get }
    var manufacturer: String? { get }
    var versionNumber: UInt16 { get }
    var descriptor: Data { get }

    // Construct the per-virtual-device session. Stateless outputs typically
    // return `self` (dual-conforming to both protocols); stateful spoofs return
    // a fresh actor instance so handshake state is scoped to one connection.
    func makeSession() -> any HIDOutputSession
}

// HIDOutputSession owns the per-connection mutable state and all the
// per-state-update encoding. One session is created when a virtual HID device
// is published and lives for that device's lifetime; the coordinator stores it
// on DeviceRecord and routes both inbound state (buildReport) and outbound
// host commands (handleSetReport) through it.
protocol HIDOutputSession: Sendable {
    func buildReport(_ state: ControllerState, source: any ControllerProfile) async -> Data
    func buildSecondaryReports(_ state: ControllerState, source: any ControllerProfile) async -> [Data]
    func handleSetReport(device: HIDVirtualDevice, type: HIDReportType, id: HIDReportID?, data: Data) async
}

extension HIDOutputSession {
    func buildSecondaryReports(_ state: ControllerState, source: any ControllerProfile) async -> [Data] { [] }
    func handleSetReport(device: HIDVirtualDevice, type: HIDReportType, id: HIDReportID?, data: Data) async {}
}

// MARK: - Native passthrough

// Delegates to a ControllerProfile so each connected controller advertises
// itself with its real VID/PID and descriptor.
struct NativeOutput: HIDOutputProfile, HIDOutputSession {
    let profile: any ControllerProfile

    var vendorID: UInt16 { profile.hidVendorID }
    var productID: UInt16 { profile.hidProductID }
    var productName: String { profile.name }
    var manufacturer: String? { "Nintendo" }
    var versionNumber: UInt16 { 0x0001 }
    var descriptor: Data { profile.hidDescriptor }

    func makeSession() -> any HIDOutputSession { self }

    func buildReport(_ state: ControllerState, source: any ControllerProfile) async -> Data {
        profile.buildHIDReport(state)
    }
}

// MARK: - Stick / hat helpers

enum SpoofEncode {
    // Map Int8 (-128..127) to UInt8 (0..255) with neutral at 128.
    static func stickX(_ v: Int8) -> UInt8 { UInt8(clamping: Int(v) + 128) }
    // Same as stickX but inverted — our parser produces "positive Y = up"
    // (game-friendly), while real DS4/DualSense/Xbox controllers send HID-
    // convention "positive Y = down".
    static func stickY(_ v: Int8) -> UInt8 { UInt8(clamping: 128 - Int(v)) }

    // Hat encoding. neutral varies by descriptor: DS4/DualSense use 0x08, while
    // standard HID null state is 0x0F.
    static func hat(up: Bool, right: Bool, down: Bool, left: Bool, neutral: UInt8) -> UInt8 {
        switch (up, right, down, left) {
        case (true,  false, false, false): return 0
        case (true,  true,  false, false): return 1
        case (false, true,  false, false): return 2
        case (false, true,  true,  false): return 3
        case (false, false, true,  false): return 4
        case (false, false, true,  true ): return 5
        case (false, false, false, true ): return 6
        case (true,  false, false, true ): return 7
        default: return neutral
        }
    }
}
