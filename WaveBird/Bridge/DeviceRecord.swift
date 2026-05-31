import Foundation

@Sendable func stderrLog(_ line: String) {
#if DEBUG
    Task.detached(priority: .background) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
#endif
}

enum DeviceConnectionState: Sendable, Equatable {
    case discovered
    case connecting
    case connected
    case ready
    case disconnected
    case failed(String)
}

struct DeviceRecord: Identifiable {
    let id: DeviceID
    let profile: any ControllerProfile
    var advertisement: AdvertisementInfo
    var connectionState: DeviceConnectionState
    var virtualHID: VirtualHIDDevice?
    var serial: String? = nil
    var firmware: FirmwareInfo? = nil
    var calibration = ControllerCalibration()
    // Populated from the 0x1FA000 flash read during init. nil = not yet read.
    var onDeviceHostAddresses: [Data]? = nil
    var outputModeID: String
    // Mode captured at the moment the virtual HID device was created. We
    // intentionally keep using this instead of the record's live outputModeID
    // while republishing so reports keep matching the active descriptor.
    var activeOutputModeID: String = ""
    // Per-virtual-device session created at .ready via the output profile's
    // makeSession(). Stateless outputs return self; stateful presentations (Switch
    // Pro) return an actor that owns handshake/mode state for this connection.
    var session: (any HIDOutputSession)?
    var awaitingProfileSelection: Bool = false
}

// One row in the controllers list. Either a currently-advertising/connected
// device (live), a previously-paired controller that isn't currently nearby
// (offline), or both at once (a live device whose serial we recognize from
// past pairings — still rendered as a live row, with a Paired badge).
struct ListEntry: Identifiable, Sendable {
    let id: String
    // The live record with its per-connection objects (virtualHID/session)
    // stripped — see listEntries. The view layer must never hold a strong
    // VirtualHIDDevice: CoreHID removes the system device only when the last
    // reference drops, and a SwiftUI value copy (e.g. a closed MenuBarExtra)
    // would pin it alive long after disconnect. Active state travels as a Bool.
    let live: DeviceRecord?
    let vhidActive: Bool
    let paired: KnownController?

    var displayName: String {
        paired?.displayName ?? live?.profile.name ?? "Unknown controller"
    }

    var serial: String? {
        live?.serial ?? paired?.serial
    }

    var isLive: Bool { live != nil }
    var isPaired: Bool { paired != nil }
}
