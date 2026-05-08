import Foundation

nonisolated struct AdvertisementInfo: Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let localName: String?
    let rssi: Int?
}

nonisolated enum DisconnectReason: Sendable {
    case userInitiated
    case timeout
    case linkLoss
    case error(String)
    case unknown
}

nonisolated enum TransportEvent: Sendable {
    case discovered(DeviceID, AdvertisementInfo)
    case connecting(DeviceID)
    case connected(DeviceID)
    case disconnected(DeviceID, DisconnectReason)
    case reportReceived(DeviceID, reportID: UInt8?, Data)
    case error(DeviceID?, String)
}
