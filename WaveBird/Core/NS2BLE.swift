@preconcurrency import CoreBluetooth

enum NS2ControllerType: Sendable {
    case joyConL, joyConR, pro, gameCube
}

// Handle ↔ UUID table for the NS2 GATT layout.
// See ndeadly/switch2_controller_research/bluetooth_interface.md.
enum NS2Handle {
    // Output (writeable) handles.
    static let commandWriteShared: UInt16 = 0x0014 // Output: Command (all controllers)
    static let commandWrite: UInt16       = 0x0016 // Output: Vibration + Command (per controller)

    // Notify handles for command responses.
    static let commandResponse1: UInt16   = 0x001A // Input: Command Response #1 (all controllers)
    static let commandResponse2: UInt16   = 0x001E // Input: Command Response #2 (per controller)

    // Input report handles.
    static let inputReport05: UInt16      = 0x000A // Input Report 0x05 (all controllers)
    static let inputReportVariant: UInt16 = 0x000E // Input Report (per controller, varies by type)

    static func uuid(_ handle: UInt16, for type: NS2ControllerType) -> CBUUID? {
        if let raw = perController[type]?[handle] { return CBUUID(string: raw) }
        if let raw = shared[handle] { return CBUUID(string: raw) }
        return nil
    }

    // Handles whose UUID is identical for every NS2 controller.
    private static let shared: [UInt16: String] = [
        0x0003: "00c5af5d-1964-4e30-8f51-1956f96bd281", // Unknown
        0x0005: "00c5af5d-1964-4e30-8f51-1956f96bd282", // Unknown
        0x0007: "00c5af5d-1964-4e30-8f51-1956f96bd283", // Unknown
        0x000A: "ab7de9be-89fe-49ad-828f-118f09df7fd2", // Input: Report 0x05
        0x0014: "649d4ac9-8eb7-4e6c-af44-1ea54fe5f005", // Output: Command
        0x0018: "4147423d-fdae-4df7-a4f7-d23e5df59f8d", // Output: Firmware Update
        0x001A: "c765a961-d9d8-4d36-a20a-5315b111836a", // Input: Command Response #1
        0x0022: "d3bd69d2-841c-4241-ab15-f86f406d2a80", // Input: Unknown
        0x0026: "ab7de9be-89fe-49ad-828f-118f09df7fde", // Input: Unknown
        0x002A: "ab7de9be-89fe-49ad-828f-118f09df7fdf", // Output: Unknown
    ]

    // Handles whose UUID varies per controller type.
    private static let perController: [NS2ControllerType: [UInt16: String]] = [
        .joyConL: [
            0x000E: "cc1bbbb5-7354-4d32-a716-a81cb241a32a", // Input: Report 0x07
            0x0012: "289326cb-a471-485d-a8f4-240c14f18241", // Output: Vibration
            0x0016: "ce49a830-dced-48ae-931e-c8cf88aadbea", // Output: Vibration + Command
            0x001E: "63a3810f-aec7-474b-9010-3d52403cb996", // Input: Command Response #2
        ],
        .joyConR: [
            0x000E: "d5a9e01e-2ffc-4cca-b20c-8b67142bf442", // Input: Report 0x08
            0x0012: "fa19b0fb-cd1f-46a7-84a1-bbb09e00c149",
            0x0016: "65a724b3-f1e7-4a61-8078-a342376b27ff",
            0x001E: "640ca58e-0e88-410c-a7f3-426faf2b690b",
        ],
        .pro: [
            0x000E: "7492866c-ec3e-4619-8258-32755ffcc0f8", // Input: Report 0x09
            0x0012: "cc483f51-9258-427d-a939-630c31f72b05",
            0x0016: "3dacbc7e-6955-40b5-8eaf-6f9809e8b379",
            0x001E: "506d9f7d-4278-4e95-a549-326ba77657e0",
        ],
        .gameCube: [
            0x000E: "8261cba1-9435-420c-84d6-f0c75a2c8e4d", // Input: Report 0x0A
            0x0012: "3f8fb670-ab25-45bf-b540-38c72834d064",
            0x0016: "af95885e-44b3-4a24-9cf0-483cc129469a",
            0x001E: "46f6ad29-cdaf-4569-a2fe-339020b94604",
        ],
    ]
}
