import Foundation

// Lightweight value-type the coordinator publishes whenever a freshly-ready
// controller is eligible for LTK pairing. The SwiftUI sheet drives off this;
// the coordinator owns mutation.
struct PairingPrompt: Sendable, Identifiable {
    let deviceID: DeviceID
    let controllerName: String
    let serial: String
    let hostAddress: Data   // 6 bytes, natural order
    var status: Status

    var id: DeviceID { deviceID }

    enum Status: Sendable, Equatable {
        case idle
        case inProgress
        case failed(String)
    }
}
