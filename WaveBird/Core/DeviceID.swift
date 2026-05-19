import Foundation

enum TransportKind: Sendable, Hashable {
    case ble
    case usb
}

struct DeviceID: Sendable, Hashable {
    let transport: TransportKind
    let raw: UUID

    init(transport: TransportKind, raw: UUID) {
        self.transport = transport
        self.raw = raw
    }
}

extension DeviceID: Identifiable {
    var id: UUID { raw }
}
