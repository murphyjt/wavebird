import CoreHID
import Foundation

nonisolated final class VirtualHIDDevice: Sendable {
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
            manufacturer: "WaveBird"
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
        0x05, 0x01,
        0x09, 0x05,
        0xA1, 0x01,
        0x09, 0x30,
        0x09, 0x31,
        0x09, 0x32,
        0x09, 0x35,
        0x15, 0x81,
        0x25, 0x7F,
        0x75, 0x08,
        0x95, 0x04,
        0x81, 0x02,
        0x09, 0x33,
        0x09, 0x34,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x02,
        0x81, 0x02,
        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x10,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x10,
        0x81, 0x02,
        0xC0
    ])
}
