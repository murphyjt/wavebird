import CoreHID
import Foundation

final class VirtualHIDDevice: Sendable {
    let device: HIDVirtualDevice
    private let delegate: Delegate

    init?(
        descriptor: Data,
        vendorID: UInt16,
        productID: UInt16,
        productName: String,
        transport: HIDDeviceTransport = .bluetoothLowEnergy
    ) {
        let properties = HIDVirtualDevice.Properties(
            descriptor: descriptor,
            vendorID: UInt32(vendorID),
            productID: UInt32(productID),
            transport: transport,
            product: productName,
            manufacturer: "Nintendo"
        )
        guard let device = HIDVirtualDevice(properties: properties) else { return nil }
        self.device = device
        self.delegate = Delegate()
    }

    func activate() async {
        await device.activate(delegate: delegate)
    }

    func dispatch(_ report: Data) async throws {
        try await device.dispatchInputReport(data: report, timestamp: .now)
    }

    private final class Delegate: HIDVirtualDeviceDelegate, Sendable {
        func hidVirtualDevice(
            _ device: HIDVirtualDevice,
            receivedSetReportRequestOfType type: HIDReportType,
            id: HIDReportID?,
            data: Data
        ) async throws {}

        func hidVirtualDevice(
            _ device: HIDVirtualDevice,
            receivedGetReportRequestOfType type: HIDReportType,
            id: HIDReportID?,
            maxSize: Int
        ) async throws -> Data {
            Data()
        }
    }
}

extension VirtualHIDDevice {
    static let placeholderGamepadDescriptor: Data = Data([
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x05,        // Usage (Game Pad)
        0xA1, 0x01,        // Collection (Application)

        0x09, 0x30,        //   Usage (X)   left  stick X  → axis 0
        0x09, 0x31,        //   Usage (Y)   left  stick Y  → axis 1
        0x09, 0x32,        //   Usage (Z)   right stick X  → axis 2
        0x09, 0x33,        //   Usage (Rx)  right stick Y  → axis 3
        0x09, 0x34,        //   Usage (Ry)  L trigger      → axis 4
        0x09, 0x35,        //   Usage (Rz)  R trigger      → axis 5
        0x15, 0x80,        //   Logical Minimum (-128)
        0x25, 0x7F,        //   Logical Maximum (127)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x06,        //   Report Count (6)
        0x81, 0x02,        //   Input (Data, Var, Abs)

        0x05, 0x09,        //   Usage Page (Button)
        0x19, 0x01,        //   Usage Minimum (1)
        0x29, 0x10,        //   Usage Maximum (16)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1)
        0x95, 0x10,        //   Report Count (16)
        0x81, 0x02,        //   Input (Data, Var, Abs)

        0xC0               // End Collection
    ])
}
