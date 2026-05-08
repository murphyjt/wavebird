import Foundation

nonisolated enum TransportKind: Sendable, Hashable {
    case ble
    case usb
}

nonisolated struct DeviceID: Sendable, Hashable {
    let transport: TransportKind
    let raw: UUID

    init(transport: TransportKind, raw: UUID) {
        self.transport = transport
        self.raw = raw
    }
}
