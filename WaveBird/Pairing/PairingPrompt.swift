import Foundation

// Lightweight value-type the coordinator publishes whenever a freshly-ready
// controller is eligible for LTK pairing. The SwiftUI sheet drives off this;
// the coordinator owns mutation.
struct PairingPrompt: Sendable, Identifiable {
    let deviceID: DeviceID
    let controllerName: String
    let serial: String
    let productID: UInt16
    let hostAddress: Data   // 6 bytes, natural order
    let intent: Intent
    var status: Status

    var id: DeviceID { deviceID }

    // The two prompt variants. Both run the full 4-step LTK exchange — the
    // only difference is the wording shown to the user. When the controller
    // already has this host's pairing entry locally-forgotten, the coordinator
    // upgrades the saved record silently and never raises a prompt.
    enum Intent: Sendable, Equatable {
        case pair      // local = no,  on-device = no
        case repair    // local = yes, on-device = no  (controller forgot us)
    }

    enum Status: Sendable, Equatable {
        case idle
        case inProgress
        case failed(String)
    }
}
