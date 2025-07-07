import Foundation

typealias Slot = UInt8

enum SlotState: UInt8 {
    case Disconnected = 0x00
    case Reserved = 0x01
    case Connected = 0x02
}

enum DeviceModel: UInt8 {
    case NotApplicable = 0x00
    case NoOrPartialGyro = 0x01
    case FullGyro = 0x02
    case ShouldNotBeUsed = 0x03
}

enum ConnectionType: UInt8 {
    case NotApplicable = 0x00
    case USB = 0x01
    case Bluetooth = 0x02
}

typealias MACAddress = [UInt8]

enum BatteryStatus: UInt8 {
    case NotApplicable = 0x00
    case Dying = 0x01
    case Low = 0x02
    case Medium = 0x03
    case High = 0x04
    case Full = 0x05
    case Charging = 0xEE
    case Charged = 0xEF
}
