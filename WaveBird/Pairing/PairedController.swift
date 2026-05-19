import Foundation

// Persisted record of a controller WaveBird has paired with on this host.
// Keyed by NS2 serial (durable hardware ID) in the coordinator's dict;
// productID lets us look up the right ControllerProfile when re-rendering
// an offline row before the controller next advertises.
struct PairedController: Codable, Sendable, Hashable {
    let serial: String
    let productID: UInt16
    // The canonical device type name (e.g. "Nintendo GameCube Controller").
    // Set from ControllerProfile.name at pair time and never modified after;
    // shown as the "Device Type" row in the offline sheet.
    let displayName: String
    var lastSeenAt: Date
    // CBPeripheral identifier we last saw this controller under on this host.
    // Lets the list dedupe offline ↔ live rows the moment the peripheral is
    // discovered, before the serial flash read lands and reveals the durable
    // hardware ID. Optional so JSON written before this field shipped still
    // decodes; the dedupe just falls back to serial-based matching.
    var peripheralUUID: UUID? = nil
    // Per-serial preferred HID output mode ("Present as"). Lets the user
    // configure it from the offline sheet and have it apply on next connect.
    // Nil means "use the global default at .ready time".
    var preferredOutputModeID: String? = nil
}
