import Foundation

// Persisted record of a controller WaveBird has interacted with on this host.
// Keyed by NS2 serial (durable hardware ID) in the coordinator's dict.
// `isPaired == true` means an LTK exchange completed or the controller's flash
// already had this host's pairing entry when WaveBird saved it;
// `false` means WaveBird has only saved a profile preference for it.
struct KnownController: Codable, Sendable, Hashable {
    let serial: String
    let productID: UInt16
    // The canonical device type name (e.g. "Nintendo GameCube Controller").
    // Set from ControllerProfile.name when first recorded and never modified after;
    // shown as the "Device Type" row in the offline sheet.
    let displayName: String
    var lastSeenAt: Date
    // CBPeripheral identifier we last saw this controller under on this host.
    // Lets the list dedupe offline ↔ live rows the moment the peripheral is
    // discovered, before the serial flash read lands and reveals the durable
    // hardware ID.
    var peripheralUUID: UUID? = nil
    // Per-serial preferred HID output mode ("Present as"). Lets the user
    // configure it from the offline sheet and have it apply on next connect.
    // Nil means "use the global default at .ready time".
    var preferredOutputModeID: String? = nil
    // True if an LTK exchange completed for this serial on this host, or if
    // the controller's flash already had this host's entry when first saved.
    // False if WaveBird has only saved a profile preference without pairing.
    var isPaired: Bool
}
