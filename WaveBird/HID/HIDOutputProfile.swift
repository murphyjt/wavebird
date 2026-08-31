import CoreHID
import Foundation

// HIDOutputProfile is the identity card for the virtual HID device we present
// to macOS — its VID/PID, descriptor, and product strings. It does NOT build
// reports; that's the session's job. The split lets stateful presentations
// (e.g. Switch Pro, which emulates Nintendo's subcommand handshake) share the
// same dispatch path as stateless ones.
//
// Output modes present as a well-known third-party controller that
// GameController.framework, web Gamepad API, and most games already have
// built-in mappings for.
//
// Presentations map shoulders/triggers via ControllerProfile.standardShoulders
// so GC's ZL/Z (digital top) land on the bumpers and L/R (analog clicks) land
// on the triggers — physically correct for each controller despite ButtonSet's
// Nintendo-flavored naming.

// Registry of available output modes. Each entry pairs a stable string ID
// (used for persistence and as the picker tag) with a display name and a
// factory that produces the HIDOutputProfile instance for a given input
// controller. Adding a new presentation is a one-line entry here plus the
// impl file — no central enum to edit.
struct HIDOutputCatalog: Sendable {
    struct Entry: Sendable, Identifiable, Hashable {
        let id: String
        let displayName: String
        let makeProfile: @Sendable (any ControllerProfile) -> any HIDOutputProfile

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
    }

    let entries: [Entry]

    func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    // Resolve to the named entry, falling back to the first allow-listed
    // entry if the ID is unknown (e.g. a persisted value from a removed mode).
    func resolved(id: String) -> Entry {
        entry(id: id) ?? entry(id: firstAllowListedID)!
    }

    // The user-facing default presentations. Used only to seed the picker's
    // initial selection so it never lands on a DEBUG-only advanced mode. The
    // advanced, in-development presentations are compiled into the catalog only
    // in DEBUG builds (see `default` below).
    static let allowListIDs: Set<String> = ["switchPro", "dualShock4", "dualSense", "xboxSeries"]

    // First allow-listed entry in catalog order — used as the default
    // selection when an advanced mode would otherwise be the initial value
    // but isn't visible, and as the fallback for unknown persisted IDs.
    var firstAllowListedID: String {
        entries.first { Self.allowListIDs.contains($0.id) }!.id
    }

    static let `default`: HIDOutputCatalog = {
        var entries: [Entry] = [
            Entry(id: "switchPro",     displayName: "Switch Pro Controller")    { _ in SwitchProOutput() },
            Entry(id: "dualShock4",    displayName: "DualShock 4")              { _ in DualShock4Output() },
            Entry(id: "dualSense",     displayName: "DualSense")                { _ in DualSenseOutput() },
            Entry(id: "xboxSeries",    displayName: "Xbox Wireless Controller") { _ in XboxSeriesOutput() },
        ]

        #if DEBUG
        entries.append(Entry(id: "ns2Passthrough", displayName: "NS2 Passthrough (raw)") { NS2PassthroughOutput(profile: $0) })
        entries.append(Entry(id: "switch2ProSDL", displayName: "Switch 2 Pro (SDL)") { _ in Switch2ProSDLOutput() })
        #endif

        return HIDOutputCatalog(entries: entries)
    }()
}

protocol HIDOutputProfile: Sendable {
    var vendorID: UInt16 { get }
    var productID: UInt16 { get }
    var productName: String { get }
    var manufacturer: String? { get }
    var versionNumber: UInt16 { get }
    var descriptor: Data { get }

    // HID report IDs this presentation needs from the controller's optional
    // secondary input channels (a subset of BLEMatcher.secondaryInputs). The
    // coordinator asks the transport to subscribe exactly these when the mode
    // activates. Default empty — only ns2Passthrough consumes Pro's Report 0x09.
    // Reports the gameplay/SDL paths use (the shared 0x05) are not secondaries
    // and are always subscribed.
    var requiredSecondaryReportIDs: Set<UInt8> { get }

    // Construct the per-virtual-device session. Stateless outputs typically
    // return `self` (dual-conforming to both protocols); stateful presentations return
    // a fresh actor instance so handshake state is scoped to one connection.
    //
    // `deviceSerial` is the NS2 serial of the controller this session serves, or
    // nil if the flash read failed. Only presentations that must expose a
    // per-device identity use it (the Switch Pro spoof derives its reported
    // Bluetooth address from it); everything else ignores it.
    func makeSession(deviceSerial: String?) -> any HIDOutputSession
}

extension HIDOutputProfile {
    var requiredSecondaryReportIDs: Set<UInt8> { [] }
}

// HIDOutputSession owns the per-connection mutable state and all the
// per-state-update encoding. One session is created when a virtual HID device
// is published and lives for that device's lifetime; the coordinator stores it
// on DeviceRecord and routes both inbound state (buildReport) and outbound
// host commands (handleSetReport) through it.
protocol HIDOutputSession: Sendable {
    func buildReport(_ state: ControllerState) async -> Data
    func buildSecondaryReports(_ state: ControllerState) async -> [Data]
    func handleSetReport(device: HIDVirtualDevice, type: HIDReportType, id: HIDReportID?, data: Data) async

    // Decode a host Set Report into a normalized RumbleCommand if this
    // session's protocol carries rumble in that report. The coordinator
    // forwards the result to ControllerProfile.encodeRumble and onto the
    // controller's vibration channel. Return nil for reports unrelated to
    // rumble (handshake, LED, etc. — those go through handleSetReport).
    func parseRumble(type: HIDReportType, id: HIDReportID?, data: Data) -> RumbleCommand?

    // Periodic re-send interval for the last non-stop rumble command. nil =
    // the host drives cadence itself (DS4/DualSense send ~30 Hz). Non-nil =
    // the host fires once and expects the device to sustain (Xbox), so the
    // coordinator re-emits at this period until either a new command arrives
    // or a stop frame cancels the loop.
    var refreshInterval: Duration? { get }

    // Raw transport-report forwarding hook for passthrough modes. Returning
    // non-nil dispatches the bytes verbatim to the VHID and SKIPS the
    // state-translation pipeline for that report. reportID is the source
    // report ID — nil for the BLE shared input (Report 0x05, unprefixed on
    // the wire), set for secondary inputs (e.g. 0x09 from Pro's per-controller
    // handle). Default returns nil — DS4/DualSense/Xbox/SwitchPro ignore raw
    // reports and rely on buildReport.
    func transformRawReport(reportID: UInt8?, data: Data) -> Data?

    // Raw transport vibration payload, derived from a host Set Report. Returning
    // non-nil bypasses parseRumble → profile.encodeRumble and is sent verbatim
    // via transport.sendVibration. Used by ns2Passthrough to relay Nintendo's
    // native Output Report 0x02 to the BLE vibration channel without
    // round-tripping through the lossy RumbleCommand model.
    func rawVibrationPayload(type: HIDReportType, id: HIDReportID?, data: Data) -> Data?
}

extension HIDOutputSession {
    func buildSecondaryReports(_ state: ControllerState) async -> [Data] { [] }
    func handleSetReport(device: HIDVirtualDevice, type: HIDReportType, id: HIDReportID?, data: Data) async {}
    func parseRumble(type: HIDReportType, id: HIDReportID?, data: Data) -> RumbleCommand? { nil }
    var refreshInterval: Duration? { nil }
    func transformRawReport(reportID: UInt8?, data: Data) -> Data? { nil }
    func rawVibrationPayload(type: HIDReportType, id: HIDReportID?, data: Data) -> Data? { nil }
}

// MARK: - NS2 raw passthrough

// Forwards raw BLE input reports as-is under a vendor HID descriptor. For Pro,
// the descriptor mirrors Nintendo's physical USB Pro Controller (reports 5/9
// in, 2 out) and we forward both BLE Report 0x05 (shared input handle) and
// Report 0x09 (per-controller input handle) verbatim. Host Set Reports
// (Report 0x02 — subcommands / rumble from SDL's Switch2 init path) are
// logged to stderr so we can see exactly what the host is trying.
struct NS2PassthroughOutput: HIDOutputProfile, HIDOutputSession {
    let profile: any ControllerProfile

    var vendorID: UInt16    { profile.hidVendorID }
    var productID: UInt16   { profile.hidProductID }
    var productName: String { profile.name }
    var manufacturer: String? { "Nintendo" }
    var versionNumber: UInt16 { 0x0001 }
    var descriptor: Data    { profile.vendorPassthroughDescriptor }

    // Passthrough forwards Pro's Report 0x09 (handle 0x000E) verbatim alongside
    // the shared 0x05, so it needs that secondary channel subscribed.
    var requiredSecondaryReportIDs: Set<UInt8> { [0x09] }

    func makeSession(deviceSerial: String?) -> any HIDOutputSession { self }

    // The state-translation pipeline is short-circuited by transformRawReport,
    // so buildReport never produces a useful frame in passthrough mode.
    func buildReport(_ state: ControllerState) async -> Data { Data() }

    // Forward each BLE input report verbatim with its HID report ID prefixed.
    // BLE delivers payloads without a leading report-ID byte; we add it so the
    // host's parser keys the data against the right descriptor entry. Payloads
    // are padded to 63 bytes (the descriptor's declared report count) when the
    // BLE frame is shorter — BLE's MTU sometimes truncates by a byte vs USB.
    func transformRawReport(reportID: UInt8?, data: Data) -> Data? {
        let id: UInt8 = reportID ?? 0x05  // Shared BLE input is unprefixed → Report 5.
        var payload = data.prefix(63)
        if payload.count < 63 {
            payload.append(Data(repeating: 0, count: 63 - payload.count))
        }
        return Data([id]) + payload
    }

    func handleSetReport(device: HIDVirtualDevice, type: HIDReportType, id: HIDReportID?, data: Data) async {
        let idStr: String
        if let id { idStr = String(format: "0x%02X", id.rawValue) } else { idStr = "—" }
        let hex = data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
        let suffix = data.count > 64 ? " … (\(data.count) bytes)" : ""
        FileHandle.standardError.write(Data(
            "[passthrough] set-report type=\(type) id=\(idStr) data=[\(hex)]\(suffix)\n".utf8
        ))
    }

    // Relay the host's Output Report 0x02 (Pro Controller native rumble format)
    // to the BLE vibration char with no re-encoding. CoreHID delivers `data` as
    // the full on-wire frame (64 bytes: report ID + 63 payload), with layout
    //   data[0]      = 0x02 (report ID)
    //   data[1]      = state byte L  (enable | ops_cnt | tid)
    //   data[2..6]   = left  LRA op  (5b, BlueRetro sw2_lra_op_t)
    //   data[7..16]  = padding
    //   data[17]     = state byte R
    //   data[18..22] = right LRA op
    //   data[23..]   = padding / reserved
    // BLE wire format is the same layout shifted: byte 0 is 0x00 (BLE framing,
    // not a HID ID) and total length is 42 bytes. Pro-only — GC's single-motor
    // 0x03 and JoyCon's 0x01 have different layouts that we don't currently
    // forward in passthrough.
    func rawVibrationPayload(type: HIDReportType, id: HIDReportID?, data: Data) -> Data? {
        guard type == .output, id?.rawValue == 0x02 else { return nil }
        guard profile.hidProductID == 0x2069 else { return nil }
        guard data.count >= 42 else { return nil }
        var payload = Data(data.prefix(42))
        payload[payload.startIndex] = 0x00
        return payload
    }
}

// MARK: - Stick / hat helpers

enum PresentationEncode {
    // Map centered 12-bit (-2047..2047) to UInt8 (0..255) with neutral at 128.
    // `>> 4` drops 12-bit to 8-bit (2047 → 127, -2047 → -128).
    static func stickX(_ v: Int16) -> UInt8 { UInt8(clamping: 128 + (Int(v) >> 4)) }
    // Same as stickX but inverted — our parser produces "positive Y = up"
    // (game-friendly), while real DS4/DualSense/Xbox controllers send HID-
    // convention "positive Y = down".
    static func stickY(_ v: Int16) -> UInt8 { UInt8(clamping: 128 - (Int(v) >> 4)) }

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
