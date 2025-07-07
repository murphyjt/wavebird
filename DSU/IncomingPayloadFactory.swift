import Foundation

class IncomingPayloadFactory {
    static func make(_ eventType: EventType, from data: Data) -> Payload? {
        switch eventType {
        case .ConnectedControllers:
            return ConnectedControllersQuery(from: data)
        case .ControllerData:
            return ControllerDataQuery(from: data)
        default:
            return nil
        }
    }
}
