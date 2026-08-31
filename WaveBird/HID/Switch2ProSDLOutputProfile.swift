import CoreHID
import Foundation

// Virtual Switch 2 Pro Controller targeted at SDL3's HIDAPI Switch2 driver
// running with the WaveBird-side patch (CoreHID `Virtual` transport →
// `device->is_virtual` → InitUSB skipped). Identifies as the real NS2 Pro
// (VID 0x057E / PID 0x2069) so the SDL driver's IsSupportedDevice matches
// it, then feeds the driver's `HandleStatePacket` parser via standard HID
// input reports instead of USB bulk transfers.
//
// Wire format alignment: SDL's parser reads exactly the same Report 0x05
// layout the NS2 emits on BLE, just shifted by one byte (the USB transport
// frames it with a leading prefix byte that BLE doesn't have). So the
// transform here is a single 1-byte left-pad on each BLE 0x05 — no field
// rearrangement, no bit packing. See ndeadly's hid_reports.md §"Input
// Report 0x05" vs `SDL_hidapi_switch2.c:944` (HandleSwitchProState) and
// `:1184` (sensor extraction at offset 0x2B onwards).
final class Switch2ProSDLOutput: HIDOutputProfile, HIDOutputSession, Sendable {
    let vendorID: UInt16 = 0x057E
    let productID: UInt16 = 0x2069
    let productName: String = "Nintendo Switch Pro Controller"
    let manufacturer: String? = "Nintendo"
    let versionNumber: UInt16 = 0x0001
    var descriptor: Data { Self.descriptor }

    func makeSession(deviceSerial: String?) -> any HIDOutputSession { self }

    // State-translation pipeline is bypassed — transformRawReport short-circuits
    // every BLE report. buildReport never runs in the dispatch path.
    func buildReport(_ state: ControllerState) async -> Data { Data() }

    // Left-pad the BLE Report 0x05 payload by one byte so its offsets line up
    // with what SDL's parser expects on the USB transport. Only forward the
    // shared input handle (BLE delivers it without a report-ID prefix → the
    // coordinator passes `reportID == nil`); Pro's per-controller secondary
    // Report 0x09 isn't part of the format SDL parses against here.
    //
    // SDL's HandleStatePacket bails on `size < 64`, so we always emit exactly
    // 64 bytes — pad short BLE frames with zeros at the tail. Byte 0 of the
    // output is unused by the parser; we leave it at 0.
    func transformRawReport(reportID: UInt8?, data: Data) -> Data? {
        guard reportID == nil else { return nil }
        // Build: [reportID=0x09, then 64 bytes of payload that SDL's parser will read].
        // The leading 0x09 satisfies CoreHID's descriptor (input is Report ID 9, 64
        // bytes); mac/hid.c then strips that ID before SDL_hid_read_timeout returns,
        // so SDL's HandleSwitchProState sees the 64-byte payload at offsets 0..0x3F.
        // The first payload byte (unused by the parser) covers the 1-byte gap
        // between BLE Report 0x05 layout and the USB Report 0x05 layout SDL keys
        // against.
        var out = Data(count: 65)
        out[0] = 0x09
        let body = data.prefix(63)
        out.replaceSubrange(2..<(2 + body.count), with: body)
        return out
    }

    // Diagnostic-only for now: SDL's rumble path will deliver bulk-format
    // packets via SDL_hid_write, which mac/hid.c routes here as Output reports.
    // The payload follows `SDL_hidapi_switch2.c:1067` UpdateRumble (Pro variant):
    //   byte 0 = 0x50 | seq nibble
    //   bytes 1-5 = HD LRA encoding (EncodeHDRumble — high/low freq + amp packed)
    // Translating that to a BLE vibration command is a follow-up; for now log
    // so we can confirm the path lights up under real input.
    func handleSetReport(device: HIDVirtualDevice, type: HIDReportType, id: HIDReportID?, data: Data) async {
        let idStr = id.map { String(format: "0x%02X", $0.rawValue) } ?? "—"
        let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        FileHandle.standardError.write(Data(
            "[switch2-sdl] set-report type=\(type) id=\(idStr) len=\(data.count) [\(hex)]\n".utf8
        ))
    }

    static let descriptor: Data = Data([
        // Generic Desktop / Game Pad outer collection so SDL's hidapi-mac
        // enumerator and only_controllers filter accept the device. Numbered
        // Input report 0x09 (matches NS2 Pro's secondary USB input ID per
        // ndeadly's table), 64 bytes; unnumbered Output report, 63 bytes
        // (SDL's UpdateRumble writes byte 0 = 0x00 for Pro and mac/hid.c
        // strips that byte before delivery — so the on-the-wire output is 63
        // bytes with no report ID).
        0x05, 0x01,              // Usage Page (Generic Desktop)
        0x09, 0x05,              // Usage (Game Pad)
        0xA1, 0x01,              // Collection (Application)

        0x06, 0x00, 0xFF,        //   Usage Page (Vendor 0xFF00)
        0x85, 0x09,              //   Report ID (9 — Input)
        0x09, 0x01,              //   Usage (Vendor 0x01 — Input payload)
        0x15, 0x00,              //   Logical Minimum (0)
        0x26, 0xFF, 0x00,        //   Logical Maximum (255)
        0x75, 0x08,              //   Report Size (8 bits)
        0x95, 0x40,              //   Report Count (64 bytes)
        0x81, 0x02,              //   Input (Data, Var, Abs)

        0x09, 0x02,              //   Usage (Vendor 0x02 — Output payload, unnumbered)
        0x95, 0x3F,              //   Report Count (63 bytes)
        0x91, 0x02,              //   Output (Data, Var, Abs)

        0xC0,                    // End Collection
    ])
}
