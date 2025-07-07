import Foundation

struct DSUConnectedControllers {
    var slot: Slot = .zero
    var state: SlotState = .Disconnected
    var model: DeviceModel = .NotApplicable
    var connectionType: ConnectionType = .NotApplicable
    var macAddress: MACAddress = [UInt8](repeating: 0, count: 6)
    var batteryStatus: BatteryStatus = .NotApplicable
}

extension DSUConnectedControllers: Payload {
    var count: Int {
        return 12
    }
    func data(using data: Data) -> Data {
        var data = data
        data.append(slot)
        data.append(state.rawValue)
        data.append(model.rawValue)
        data.append(connectionType.rawValue)
        data.append(contentsOf: macAddress)
        data.append(batteryStatus.rawValue)
        data.append(0)
        return data
    }
}
