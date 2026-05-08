import Foundation

struct AdvertisementInfo: Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let localName: String?
    let rssi: Int?
}

enum DisconnectReason: Sendable {
    case userInitiated
    case timeout
    case linkLoss
    case error(String)
    case unknown
}

enum TransportEvent: Sendable {
    case discovered(DeviceID, AdvertisementInfo)
    case connecting(DeviceID)
    case connected(DeviceID)
    case ready(DeviceID)
    case disconnected(DeviceID, DisconnectReason)
    case reportReceived(DeviceID, reportID: UInt8?, Data)
    case error(DeviceID?, String)
}
