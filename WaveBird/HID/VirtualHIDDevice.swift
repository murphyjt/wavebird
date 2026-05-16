import CoreHID
import Foundation

final class VirtualHIDDevice: Sendable {
    let device: HIDVirtualDevice
    private let delegate: Delegate

    // Called for every Set Report request the host sends to the virtual device.
    // `data` is the report payload (excluding the leading ID byte; the parsed
    // ID is passed separately). The handler may dispatch a corresponding Input
    // Report back via the `device` argument — that's how the Switch Pro spoof
    // services the subcommand handshake.
    typealias SetReportHandler = @Sendable (HIDVirtualDevice, HIDReportType, HIDReportID?, Data) async -> Void

    init?(
        descriptor: Data,
        vendorID: UInt16,
        productID: UInt16,
        productName: String,
        manufacturer: String? = "Nintendo",
        versionNumber: UInt16 = 0x0001,
        serialNumber: String? = nil,
        transport: HIDDeviceTransport = .bluetoothLowEnergy,
        onSetReport: SetReportHandler? = nil
    ) {
        let properties = HIDVirtualDevice.Properties(
            descriptor: descriptor,
            vendorID: UInt32(vendorID),
            productID: UInt32(productID),
            transport: transport,
            product: productName,
            manufacturer: manufacturer,
            versionNumber: UInt64(versionNumber),
            serialNumber: serialNumber,
        )
        guard let device = HIDVirtualDevice(properties: properties) else {
            let hex = descriptor.map { String(format: "%02X", $0) }.joined(separator: " ")
            FileHandle.standardError.write(Data(
                "[hid] HIDVirtualDevice init failed — vid=0x\(String(format: "%04X", vendorID)) pid=0x\(String(format: "%04X", productID)) descriptor(\(descriptor.count)b)=[\(hex)]\n"
                .utf8
            ))
            FileHandle.standardError.write(Data(
                "[hid] check: log show --predicate 'subsystem==\"com.apple.CoreHID\"' --last 1m\n"
                .utf8
            ))
            return nil
        }
        self.device = device
        self.delegate = Delegate(onSetReport: onSetReport)
    }

    func activate() async {
        await device.activate(delegate: delegate)
    }

    func dispatch(_ report: Data) async throws {
        try await device.dispatchInputReport(data: report, timestamp: .now)
    }

    private final class Delegate: HIDVirtualDeviceDelegate, Sendable {
        let onSetReport: SetReportHandler?

        init(onSetReport: SetReportHandler?) {
            self.onSetReport = onSetReport
        }

        func hidVirtualDevice(
            _ device: HIDVirtualDevice,
            receivedSetReportRequestOfType type: HIDReportType,
            id: HIDReportID?,
            data: Data
        ) async throws {
            await onSetReport?(device, type, id, data)
        }

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

    // Standard gamepad: 4 stick axes + 2 trigger axes + 8-way hat + 16 buttons.
    // Mirrors the input shape SDL exposes for both NS2 GameCube and Pro controllers
    // (the controllers differ only in what fills the trigger axes — analog for GC,
    // digital 0/0xFF for Pro). Report size: 9 bytes.
    //
    // Report layout:
    //   byte 0: X   (left stick X, Int8 -127..127)
    //   byte 1: Y   (left stick Y, Int8)
    //   byte 2: Z   (right stick X, Int8)
    //   byte 3: Rz  (right stick Y, Int8)
    //   byte 4: Rx  (left trigger,  UInt8 0..255)
    //   byte 5: Ry  (right trigger, UInt8 0..255)
    //   byte 6: hat (low 4 bits: 0=N,1=NE,…,7=NW, 0xF=neutral) + padding
    //   byte 7-8: 16 buttons (Button 1 in bit 0 of byte 7)
    static let standardGamepadDescriptor: Data = Data([
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x05,        // Usage (Game Pad)
        0xA1, 0x01,        // Collection (Application)

        // 4 stick axes (signed)
        0x09, 0x30,        //   Usage (X)   left  stick X
        0x09, 0x31,        //   Usage (Y)   left  stick Y
        0x09, 0x32,        //   Usage (Z)   right stick X
        0x09, 0x35,        //   Usage (Rz)  right stick Y
        0x15, 0x80,        //   Logical Minimum (-128)
        0x25, 0x7F,        //   Logical Maximum (127)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x04,        //   Report Count (4)
        0x81, 0x02,        //   Input (Data, Var, Abs)

        // 2 trigger axes (unsigned 0..255 — standard trigger encoding)
        0x09, 0x33,        //   Usage (Rx)  left  trigger
        0x09, 0x34,        //   Usage (Ry)  right trigger
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x00,  //   Logical Maximum (255)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x02,        //   Report Count (2)
        0x81, 0x02,        //   Input (Data, Var, Abs)

        // 8-way hat for the D-pad (4-bit field, null state at 0xF)
        0x09, 0x39,        //   Usage (Hat switch)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x07,        //   Logical Maximum (7)
        0x35, 0x00,        //   Physical Minimum (0)
        0x46, 0x3B, 0x01,  //   Physical Maximum (315)
        0x65, 0x14,        //   Unit (English Rotation: Degrees)
        0x75, 0x04,        //   Report Size (4)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x42,        //   Input (Data, Var, Abs, Null state)

        // 4 padding bits to byte-align the buttons
        0x75, 0x04,        //   Report Size (4)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x03,        //   Input (Const, Var, Abs)
        0x65, 0x00,        //   Unit (None) — reset rotation unit so it doesn't leak

        // 16 buttons
        0x05, 0x09,        //   Usage Page (Button)
        0x19, 0x01,        //   Usage Minimum (Button 1)
        0x29, 0x10,        //   Usage Maximum (Button 16)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1)
        0x95, 0x10,        //   Report Count (16)
        0x81, 0x02,        //   Input (Data, Var, Abs)

        0xC0               // End Collection
    ])

    // GC gamepad: same input layout as standardGamepadDescriptor under Report ID 0x01,
    // plus Output Report ID 0x03 (3 bytes, vendor-defined) for the simple on/off motor.
    // Using report IDs requires the input report wire format to include the leading 0x01 byte.
    static let gcGamepadDescriptor: Data = Data([
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x05,        // Usage (Game Pad)
        0xA1, 0x01,        // Collection (Application)

        0x85, 0x01,        //   Report ID (1) — input

        // 4 stick axes (signed)
        0x09, 0x30,        //   Usage (X)   left  stick X
        0x09, 0x31,        //   Usage (Y)   left  stick Y
        0x09, 0x32,        //   Usage (Z)   right stick X
        0x09, 0x35,        //   Usage (Rz)  right stick Y
        0x15, 0x80,        //   Logical Minimum (-128)
        0x25, 0x7F,        //   Logical Maximum (127)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x04,        //   Report Count (4)
        0x81, 0x02,        //   Input (Data, Var, Abs)

        // 2 trigger axes (unsigned 0..255)
        0x09, 0x33,        //   Usage (Rx)  left  trigger
        0x09, 0x34,        //   Usage (Ry)  right trigger
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x00,  //   Logical Maximum (255)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x02,        //   Report Count (2)
        0x81, 0x02,        //   Input (Data, Var, Abs)

        // 8-way hat for the D-pad (4-bit field, null state at 0xF)
        0x09, 0x39,        //   Usage (Hat switch)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x07,        //   Logical Maximum (7)
        0x35, 0x00,        //   Physical Minimum (0)
        0x46, 0x3B, 0x01,  //   Physical Maximum (315)
        0x65, 0x14,        //   Unit (English Rotation: Degrees)
        0x75, 0x04,        //   Report Size (4)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x42,        //   Input (Data, Var, Abs, Null state)

        // 4 padding bits to byte-align the buttons
        0x75, 0x04,        //   Report Size (4)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x03,        //   Input (Const, Var, Abs)
        0x65, 0x00,        //   Unit (None)

        // 16 buttons
        0x05, 0x09,        //   Usage Page (Button)
        0x19, 0x01,        //   Usage Minimum (Button 1)
        0x29, 0x10,        //   Usage Maximum (Button 16)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1)
        0x95, 0x10,        //   Report Count (16)
        0x81, 0x02,        //   Input (Data, Var, Abs)

        // Output Report ID 0x03 — GC motor rumble (vendor-defined).
        // SDL allocates a 64-byte buffer; HIDAPI strips byte 0 as the report ID
        // and calls IOHIDDeviceSetReport with the remaining 63 bytes. CoreHID
        // validates length against the descriptor, so declare 63 bytes here.
        // The BLE write only forwards the first 4 bytes ([0x03, seq, val, pad]).
        0x06, 0x00, 0xFF,  //   Usage Page (Vendor 0xFF00)
        0x09, 0x01,        //   Usage (Vendor 0x01)
        0x85, 0x03,        //   Report ID (3)
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x00,  //   Logical Maximum (255)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x3F,        //   Report Count (63)
        0x91, 0x02,        //   Output (Data, Var, Abs)

        0xC0               // End Collection
    ])

    // Vendor passthrough descriptor: single input report, report ID `reportID`,
    // `byteCount` unsigned bytes, usage page 0xFF00. Used for ns2Passthrough mode.
    static func ns2VendorDescriptor(reportID: UInt8, byteCount: Int) -> Data {
        Data([
            0x06, 0x00, 0xFF,        // Usage Page (Vendor 0xFF00)
            0x09, 0x01,              // Usage (Vendor 0x01)
            0xA1, 0x01,              // Collection (Application)
            0x85, reportID,          //   Report ID
            0x09, 0x01,              //   Usage (Vendor)
            0x15, 0x00,              //   Logical Minimum (0)
            0x26, 0xFF, 0x00,        //   Logical Maximum (255)
            0x75, 0x08,              //   Report Size (8)
            0x95, UInt8(byteCount),  //   Report Count
            0x81, 0x02,              //   Input (Data, Var, Abs)
            0xC0,                    // End Collection
        ])
    }

    // Encode the four dpad booleans as an 8-position hat. 0=N, 1=NE, …, 7=NW, 0xF=neutral.
    static func hatValue(up: Bool, right: Bool, down: Bool, left: Bool) -> UInt8 {
        switch (up, right, down, left) {
        case (true,  false, false, false): return 0
        case (true,  true,  false, false): return 1
        case (false, true,  false, false): return 2
        case (false, true,  true,  false): return 3
        case (false, false, true,  false): return 4
        case (false, false, true,  true ): return 5
        case (false, false, false, true ): return 6
        case (true,  false, false, true ): return 7
        default: return 0x0F
        }
    }
}
