import CoreHID
import Foundation

// NS2 relay: the virtual device IS the controller. Real VID/PID, the real
// report set, and a vendor tunnel (0x80 out / 0x81 in) that carries SDL's
// Switch 2 driver commands to the BLE command characteristic. WaveBird moves
// bytes; SDL owns the protocol. Contract: docs/superpowers/specs/
// 2026-09-10-ns2-relay-design.md §"The HID contract" (mirrored verbatim in
// SDL's InitVirtual header comment).
//
// Stateless: every transform is a pure function of the report bytes, so
// makeSession returns self. Set-report `data` arrives with the report ID at
// index 0 (CoreHID's on-wire framing — see DualSenseOutput.parseRumble).
struct NS2RelayOutput: HIDOutputProfile, HIDOutputSession {
    let profile: any ControllerProfile

    static let tunnelRequestReportID: UInt8 = 0x80
    static let tunnelResponseReportID: UInt8 = 0x81
    static let tunnelResponseLength = 80
    // Every NS2 rumble encoder in WaveBird emits 42 bytes; the controller
    // accepts exactly that from us, so the relayed packet is cut to match.
    static let rumblePayloadLength = 42
    static let stateReportLength = 63

    var vendorID: UInt16      { profile.hidVendorID }
    var productID: UInt16     { profile.hidProductID }
    var productName: String   { profile.name }
    var manufacturer: String? { "Nintendo" }
    var versionNumber: UInt16 { 0x0001 }
    var descriptor: Data      { profile.relayDescriptor }

    func makeSession(deviceSerial: String?) -> any HIDOutputSession { self }

    // transformRawReport short-circuits every report, so this never runs.
    func buildReport(_ state: ControllerState) async -> Data { Data() }

    // Native rumble Output Report ID per controller (SDL UpdateRumble:
    // rumble_data[0] = 0x1 Joy-Con, 0x2 Pro, 0x3 GC).
    static func rumbleReportID(forProductID pid: UInt16) -> UInt8? {
        switch pid {
        case 0x2069: 0x02
        case 0x2073: 0x03
        case 0x2066, 0x2067: 0x01
        default: nil
        }
    }

    // Shared input handle 0x000A (unprefixed on BLE) → Input Report 0x05,
    // padded to the descriptor's 63 bytes when BLE truncates. Byte-identical
    // to the controller's USB HID input, so SDL's parser needs no change.
    // Anything with a report ID is a secondary channel — never forwarded.
    func transformRawReport(reportID: UInt8?, data: Data) -> Data? {
        guard reportID == nil else { return nil }
        var out = Data([0x05])
        out.append(data.prefix(Self.stateReportLength))
        if out.count < Self.stateReportLength + 1 {
            out.append(Data(repeating: 0, count: Self.stateReportLength + 1 - out.count))
        }
        return out
    }

    // Host rumble report for this controller → vibration characteristic,
    // verbatim except byte 0 (the HID report ID) becomes 0x00, the BLE
    // framing byte. SDL packs the LRA ops in the layout WaveBird's own
    // encoders use, so nothing is re-encoded.
    func rawVibrationPayload(type: HIDReportType, id: HIDReportID?, data: Data) -> Data? {
        guard type == .output,
              let expected = Self.rumbleReportID(forProductID: profile.hidProductID),
              id?.rawValue == expected,
              data.count >= Self.rumblePayloadLength
        else { return nil }
        var payload = Data(data.prefix(Self.rumblePayloadLength))
        payload[payload.startIndex] = 0x00
        return payload
    }

    // Output Report 0x80 → BLE command frame. SDL sends exactly `8 + len`
    // bytes over bulk (init_sequence[i][5] + 8); the rest of the report is
    // zero padding, so it is cut here. Byte 2 is the transport marker: SDL
    // writes 0x00 (USB); every hardware-validated WaveBird frame uses 0x01.
    // Cmd 0x15 (LTK pairing) is dropped — a host must never rewrite the key.
    func relayCommand(type: HIDReportType, id: HIDReportID?, data: Data) -> Data? {
        guard type == .output, id?.rawValue == Self.tunnelRequestReportID else { return nil }
        let frame = data.dropFirst()
        guard frame.count >= 8 else { return nil }
        let f = frame.startIndex
        let length = 8 + Int(frame[f + 5])
        guard frame.count >= length else { return nil }
        if frame[f] == 0x15 {
            stderrLog("[relay] dropped cmd 0x15 (pairing) from host")
            return nil
        }
        var out = Data(frame.prefix(length))
        out[out.startIndex + 2] = 0x01
        return out
    }

    // Response frame → Input Report 0x81, zero-padded to the declared 80
    // bytes. Responses are never modified (SDL doesn't read byte 2).
    static func tunnelResponseReport(_ response: Data) -> Data {
        var out = Data([tunnelResponseReportID])
        out.append(response.prefix(tunnelResponseLength))
        if out.count < tunnelResponseLength + 1 {
            out.append(Data(repeating: 0, count: tunnelResponseLength + 1 - out.count))
        }
        return out
    }
}
