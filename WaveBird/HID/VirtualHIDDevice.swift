import CoreHID
import Foundation

final class VirtualHIDDevice: Sendable {
    let device: HIDVirtualDevice
    private let delegate: Delegate

    // Called for every Set Report request the host sends to the virtual device.
    // `data` is the on-wire frame including the report ID at index 0 (the
    // parsed ID is also passed separately) — every parser in HID/ indexes
    // from 1. The handler may dispatch a corresponding Input
    // Report back via the `device` argument — that's how the Switch Pro presentation
    // services the subcommand handshake.
    typealias SetReportHandler = @Sendable (HIDVirtualDevice, HIDReportType, HIDReportID?, Data) async -> Void
    typealias GetReportHandler = @Sendable (HIDReportType, HIDReportID?, Int) async -> Data?

    init?(
        descriptor: Data,
        vendorID: UInt16,
        productID: UInt16,
        productName: String,
        manufacturer: String? = "Nintendo",
        versionNumber: UInt16 = 0x0001,
        serialNumber: String? = nil,
        transport: HIDDeviceTransport = .bluetoothLowEnergy,
        onSetReport: SetReportHandler? = nil,
        onGetReport: GetReportHandler? = nil
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
        self.delegate = Delegate(onSetReport: onSetReport, onGetReport: onGetReport)
    }

    func activate() async {
        await device.activate(delegate: delegate)
    }

    func dispatch(_ report: Data) async throws {
        try await device.dispatchInputReport(data: report, timestamp: .now)
    }

    private final class Delegate: HIDVirtualDeviceDelegate, Sendable {
        let onSetReport: SetReportHandler?
        let onGetReport: GetReportHandler?

        init(onSetReport: SetReportHandler?, onGetReport: GetReportHandler?) {
            self.onSetReport = onSetReport
            self.onGetReport = onGetReport
        }

        func hidVirtualDevice(
            _ device: HIDVirtualDevice,
            receivedSetReportRequestOfType type: HIDReportType,
            id: HIDReportID?,
            data: Data
        ) async throws {
            await onSetReport?(device, type, id, data)
        }

        // Every Get Report currently answers empty. Logged because an
        // unanswered feature read can silently gate driver behaviour — Sony
        // pads publish IMU calibration this way (SDL reads
        // k_EPS5FeatureReportIdCalibration before enabling sensors), so a
        // driver asking here and getting nothing is a plausible reason for
        // motion to stay dead.
        func hidVirtualDevice(
            _ device: HIDVirtualDevice,
            receivedGetReportRequestOfType type: HIDReportType,
            id: HIDReportID?,
            maxSize: Int
        ) async throws -> Data {
            let answer = await onGetReport?(type, id, maxSize) ?? Data()
            let idStr = id.map { String(format: "0x%02X", $0.rawValue) } ?? "-"
            stderrLog("[hid] getReport type=\(type) id=\(idStr) maxSize=\(maxSize) -> \(answer.count) bytes")
            return answer
        }
    }
}

extension VirtualHIDDevice {
    // Tunnel reports for the NS2 relay mode (spec: docs/superpowers/specs/
    // 2026-09-10-ns2-relay-design.md §"The HID contract"). Appended inside a
    // Game Pad application collection; sets its own usage page so it is
    // independent of whatever page precedes it.
    //   0x80 Output, 64 bytes — command request frame (SDL → controller)
    //   0x81 Input,  80 bytes — command response frame (controller → SDL)
    static let ns2TunnelDescriptorBlock: Data = Data([
        0x06, 0x00, 0xFF,        // Usage Page (Vendor 0xFF00)
        0x85, 0x80,              // Report ID (0x80)
        0x09, 0x03,              // Usage (Vendor 0x03 — command request)
        0x15, 0x00,              // Logical Minimum (0)
        0x26, 0xFF, 0x00,        // Logical Maximum (255)
        0x75, 0x08,              // Report Size (8)
        0x95, 0x40,              // Report Count (64)
        0x91, 0x02,              // Output (Data, Var, Abs)
        0x85, 0x81,              // Report ID (0x81)
        0x09, 0x04,              // Usage (Vendor 0x04 — command response)
        0x95, 0x50,              // Report Count (80)
        0x81, 0x02,              // Input (Data, Var, Abs)
    ])

    // Relay descriptor for controllers whose real USB descriptor we don't
    // carry (GC, Joy-Con). The Generic Desktop / Game Pad outer collection is
    // load-bearing: SDL's HIDAPI_IGNORE_DEVICE drops any device whose top-level
    // usage isn't Joystick/Game Pad/Multi-axis when
    // SDL_HINT_HIDAPI_ENUMERATE_ONLY_CONTROLLERS is on (the default).
    //   0x05 Input,  63 bytes — controller state (BLE Report 0x05 verbatim)
    //   rumbleOutputReportID Output, 63 bytes — native rumble packet
    //   + ns2TunnelDescriptorBlock
    static func ns2RelayDescriptor(rumbleOutputReportID: UInt8) -> Data {
        var d = Data([
            0x05, 0x01,              // Usage Page (Generic Desktop)
            0x09, 0x05,              // Usage (Game Pad)
            0xA1, 0x01,              // Collection (Application)
            0x06, 0x00, 0xFF,        //   Usage Page (Vendor 0xFF00)
            0x85, 0x05,              //   Report ID (5)
            0x09, 0x01,              //   Usage (Vendor 0x01 — state)
            0x15, 0x00,              //   Logical Minimum (0)
            0x26, 0xFF, 0x00,        //   Logical Maximum (255)
            0x75, 0x08,              //   Report Size (8)
            0x95, 0x3F,              //   Report Count (63)
            0x81, 0x02,              //   Input (Data, Var, Abs)
            0x85, rumbleOutputReportID, // Report ID (rumble)
            0x09, 0x02,              //   Usage (Vendor 0x02 — rumble)
            0x95, 0x3F,              //   Report Count (63)
            0x91, 0x02,              //   Output (Data, Var, Abs)
        ])
        d.append(ns2TunnelDescriptorBlock)
        d.append(0xC0)               // End Collection
        return d
    }
}

extension VirtualHIDDevice {
    // gamecontrollerd persists its per-device record keyed on the HID serial
    // number ALONE — the entries in com.apple.GameController.plist are
    // identified as `LOGICAL_DEVICE(<serial>)`, with no VID/PID component.
    // Handing every output mode the same controller serial therefore collides
    // all of WaveBird's presentations onto one record: publish the Switch Pro
    // VHID after the DualSense one and the cached record still reads
    // PRODUCT_CATEGORY_DUALSENSE, so a Nintendo 0x057E/0x2009 device is
    // classified and drawn as a PlayStation pad. Scoping the serial by output
    // mode gives each presentation its own record.
    //
    // Observed on macOS 27.0 (26A5421a) 2026-08-30: one live "Pro Controller"
    // VHID, no DualSense HID device on the system, and a plist entry
    // `LOGICAL_DEVICE(HEW80007222278)` / name "Pro Controller" /
    // PRODUCT_CATEGORY_DUALSENSE left over from the DualSense mode.
    //
    // Nothing reads this value back — it is only ever handed to CoreHID. The
    // Switch-protocol serial the Pro presentation serves from emulated SPI
    // flash is a separate value and is not affected.
    static func hidSerialNumber(deviceSerial: String?, modeID: String) -> String? {
        deviceSerial.map { "\($0)-\(modeID)" }
    }
}
