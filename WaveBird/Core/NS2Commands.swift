import Foundation

// Shared NS2 BLE command frames and flash-response parsers. These are identical
// across the GameCube, Pro and JoyCon profiles; only feature-mask byte and the
// per-controller report parsing differ.
//
// Frame layout (per CLAUDE.md / ndeadly's research):
//   [cmdID, 0x91, 0x01, subcmdID, 0x00, payloadLen, 0x00, 0x00, …payload]
//
// References:
// - libsdl-org/SDL (src/joystick/hidapi/SDL_hidapi_switch2.c)
// - darthcloud/BlueRetro (main/bluetooth/hidp/sw2.c, Apache-2.0)
// - ndeadly switch2_controller_research (commands.md, bluetooth_interface.md)
enum NS2Commands {
    // Cmd 0x07/0x01 — opaque handshake. Always the first command sent on connect.
    static let handshake = Data([
        0x07, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
    ])

    // Cmd 0x02/0x04 — read 0x40 bytes from flash 0x13000 (factory block: serial + more).
    static let factoryDataRead = Data([
        0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00,
        0x40, 0x7E, 0x00, 0x00, 0x00, 0x30, 0x01, 0x00,
    ])

    // Cmd 0x02/0x04 — read 0x40 bytes from flash 0x13080: factory left-stick calibration block.
    // The 9-byte calibration record sits at offset 0x28 inside the block (i.e. flash 0x130A8).
    static let leftStickCalibrationRead = Data([
        0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00,
        0x40, 0x7E, 0x00, 0x00, 0x80, 0x30, 0x01, 0x00,
    ])

    // Cmd 0x02/0x04 — read 0x40 bytes from flash 0x130C0: factory right-stick calibration block.
    static let rightStickCalibrationRead = Data([
        0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00,
        0x40, 0x7E, 0x00, 0x00, 0xC0, 0x30, 0x01, 0x00,
    ])

    // Cmd 0x02/0x04 — read 0x40 bytes from flash 0x1FA000: BT pairing block.
    // Decodes to (item count, host_addr_1, LTK_1, host_addr_2, LTK_2).
    // Used at .ready to detect whether *this* Mac is one of the stored hosts.
    static let pairingInfoRead = Data([
        0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00,
        0x40, 0x7E, 0x00, 0x00, 0x00, 0xA0, 0x1F, 0x00,
    ])

    // Cmd 0x10/0x01 — get firmware version info.
    static let firmwareInfo = Data([
        0x10, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
    ])

    // Cmd 0x0A/0x02 — play vibration sample 0x03 ("connection" tone).
    static let connectionVibration = Data([
        0x0A, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00,
    ])

    // Cmd 0x09/0x07 — set LED bitmask to Player 1.
    static let player1LED = Data([
        0x09, 0x91, 0x01, 0x07, 0x00, 0x08, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    // Cmd 0x0A/0x08 — "send vibration data". Format not publicly documented; purpose during
    // init is unverified. Both SDL ("Set rumble data?") and BlueRetro send this same payload
    // before turning on the feature mask, so we mirror it.
    static let sendVibrationData = Data([
        0x0A, 0x91, 0x01, 0x08, 0x00, 0x14, 0x00, 0x00,
        0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0x35, 0x00, 0x46, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])

    // Cmd 0x0C/0x02 — declare which features are allowed in subsequent enable/disable calls.
    static func setFeatureMask(_ features: NS2Feature) -> Data {
        Data([
            0x0C, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00,
            features.rawValue, 0x00, 0x00, 0x00,
        ])
    }

    // Cmd 0x0C/0x04 — turn on the features set in the mask above.
    static func enableFeatures(_ features: NS2Feature) -> Data {
        Data([
            0x0C, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00,
            features.rawValue, 0x00, 0x00, 0x00,
        ])
    }
}

// Feature flags accepted by cmd 0x0C subcommands 0x02 (set mask) / 0x04 (enable) /
// 0x05 (disable). Bits per ndeadly's commands.md "Feature Flags" table.
struct NS2Feature: OptionSet, Sendable {
    let rawValue: UInt8

    static let buttons      = NS2Feature(rawValue: 1 << 0)  // 0x01
    static let analog       = NS2Feature(rawValue: 1 << 1)  // 0x02
    static let imu          = NS2Feature(rawValue: 1 << 2)  // 0x04 — accel + gyro
    // Bit 3 is documented as "Unused" but SDL and BlueRetro both set it for Pro.
    // Purpose unverified; included so we can mirror existing behaviour.
    static let unknown3     = NS2Feature(rawValue: 1 << 3)  // 0x08
    static let mouse        = NS2Feature(rawValue: 1 << 4)  // 0x10 — JoyCon only
    static let rumble       = NS2Feature(rawValue: 1 << 5)  // 0x20
    static let magnetometer = NS2Feature(rawValue: 1 << 7)  // 0x80
}

// Parsers for the response payloads returned by `NS2Commands.*Read` flash reads.
enum NS2Responses {
    // Input: the 0x40-byte flash block read from 0x13000 (response with ACK + read-info stripped).
    //   [0..1] record marker (01 00)
    //   [2..16] 15-byte ASCII serial number
    static func parseSerial(_ flashData: Data) -> String? {
        guard flashData.count >= 17 else { return nil }
        let b = flashData.startIndex
        let field = flashData[(b + 2)..<(b + 17)]
        let printable = field.prefix(while: { (0x20...0x7E).contains($0) })
        guard !printable.isEmpty else { return nil }
        return String(decoding: printable, as: UTF8.self)
    }

    // Input: the cmd 0x10/0x01 response payload (response with 8-byte ACK header stripped).
    //   [0..2] controller fw major.minor.micro
    //   [3]    controller type (0x03 = GameCube, 0x02 = Pro, 0x00 = JoyCon L, 0x01 = JoyCon R)
    //   [4..6] Bluetooth patch major.minor.micro
    //   [7]    padding; [8..] DSP firmware (Pro only)
    static func parseFirmwareInfo(_ payload: Data) -> FirmwareInfo? {
        guard payload.count >= 7 else { return nil }
        let b = payload.startIndex
        return FirmwareInfo(
            controllerVersion: (payload[b + 0], payload[b + 1], payload[b + 2]),
            controllerType: payload[b + 3],
            bluetoothPatch: (payload[b + 4], payload[b + 5], payload[b + 6])
        )
    }

    // Input: the 0x40-byte flash block read from 0x1FA000.
    // Layout (per memory_layout.md §0x1FA000-0x1FAFFF):
    //   [0x00]      item count (0..2)
    //   [0x08..0E]  host address #1 (6 bytes, natural MSB-first)
    //   [0x1A..2A]  LTK #1 (16 bytes; not retained — we only need address match)
    //   [0x30..36]  host address #2 (6 bytes)
    //   [0x42..52]  LTK #2 (16 bytes)
    static func parsePairingInfo(_ flashBlock: Data) -> [Data] {
        guard flashBlock.count >= 0x36 else { return [] }
        let b = flashBlock.startIndex
        let count = Int(flashBlock[b])
        guard (0...2).contains(count) else { return [] }
        var addresses: [Data] = []
        if count >= 1 {
            addresses.append(Data(flashBlock[(b + 0x08)..<(b + 0x0E)]))
        }
        if count >= 2 {
            addresses.append(Data(flashBlock[(b + 0x30)..<(b + 0x36)]))
        }
        return addresses
    }

    // Input: the 0x40-byte flash block read from 0x13080 (or 0x130C0).
    // The 9-byte stick calibration record lives at offset 0x28 inside the block.
    // Packing (per axis, 12-bit, little-endian nibble-packed):
    //   bytes 0..2 → neutralX, neutralY
    //   bytes 3..5 → maxX (above center), maxY
    //   bytes 6..8 → minX (below center), minY
    // Layout from SDL (ParseStickCalibration) and BlueRetro (bt_hid_sw2_set_calib).
    static func parseStickCalibration(_ flashBlock: Data) -> StickCalibration? {
        guard flashBlock.count >= 0x28 + 9 else { return nil }
        let b = flashBlock.startIndex.advanced(by: 0x28)
        let nX = UInt16(flashBlock[b])       | (UInt16(flashBlock[b + 1] & 0x0F) << 8)
        let nY = UInt16(flashBlock[b + 1] >> 4) | (UInt16(flashBlock[b + 2]) << 4)
        let mxX = UInt16(flashBlock[b + 3])      | (UInt16(flashBlock[b + 4] & 0x0F) << 8)
        let mxY = UInt16(flashBlock[b + 4] >> 4) | (UInt16(flashBlock[b + 5]) << 4)
        let mnX = UInt16(flashBlock[b + 6])      | (UInt16(flashBlock[b + 7] & 0x0F) << 8)
        let mnY = UInt16(flashBlock[b + 7] >> 4) | (UInt16(flashBlock[b + 8]) << 4)
        return StickCalibration(neutralX: nX, neutralY: nY, maxX: mxX, maxY: mxY, minX: mnX, minY: mnY)
    }

    // Extract the little-endian flash address from a cmd 0x02 / 0x04 request.
    // Exposed so the coordinator can label flash hexdumps without re-parsing.
    static func flashReadAddress(of request: Data) -> Int? {
        guard request.count >= 16 else { return nil }
        let b = request.startIndex
        return Int(request[b + 12])
            | (Int(request[b + 13]) << 8)
            | (Int(request[b + 14]) << 16)
            | (Int(request[b + 15]) << 24)
    }

    // Default ControllerProfile.handleCommandResponse dispatch: maps the
    // addresses every NS2 controller shares (serial / firmware / stick cal)
    // to their parsers. Profiles call this from their override after handling
    // any controller-specific addresses (e.g. GC trigger zeros at 0x13140).
    static func parseStandard(request: Data, response: Data) -> ControllerMetadata? {
        switch request.first {
        case 0x02:
            guard let address = flashReadAddress(of: request) else { return nil }
            let flashData = response.dropFirst(16)
            switch address {
            case 0x13000:
                return parseSerial(flashData).map { ControllerMetadata(serial: $0) }
            case 0x13080:
                return parseStickCalibration(flashData).map { ControllerMetadata(leftCalibration: $0) }
            case 0x130C0:
                return parseStickCalibration(flashData).map { ControllerMetadata(rightCalibration: $0) }
            case 0x1FA000:
                return ControllerMetadata(onDeviceHostAddresses: parsePairingInfo(flashData))
            default:
                return nil
            }
        case 0x10:
            return parseFirmwareInfo(response.dropFirst(8)).map { ControllerMetadata(firmware: $0) }
        default:
            return nil
        }
    }
}

// Stick decoding + calibration helpers, shared across NS2 profiles. Report 0x05 (and the
// per-controller reports 0x09 / 0x0A) all encode each stick as 3 bytes of packed 12-bit
// X/Y values.
enum NS2Sticks {
    enum Axis { case x, y }

    // Unpack 3 bytes into a pair of 12-bit values: (X, Y).
    static func unpack(_ data: Data, at i: Int) -> (UInt16, UInt16) {
        let b0 = UInt16(data[i])
        let b1 = UInt16(data[i + 1])
        let b2 = UInt16(data[i + 2])
        return (b0 | ((b1 & 0x0F) << 8), (b1 >> 4) | (b2 << 4))
    }

    // Apply per-stick factory calibration if available; otherwise fall back to a centered
    // linear map. Calibration math mirrors SDL's MapJoystickAxis
    // (libsdl-org/SDL: src/joystick/hidapi/SDL_hidapi_switch2.c): translate by neutral,
    // divide by the per-side extent, scale to Int8 range, clamp.
    static func axis(_ raw: UInt16, _ cal: StickCalibration?, axis: Axis, invert: Bool = false) -> Int8 {
        let neutral: UInt16
        let maxAbove: UInt16
        let maxBelow: UInt16
        if let c = cal {
            switch axis {
            case .x: neutral = c.neutralX; maxAbove = c.maxX; maxBelow = c.minX
            case .y: neutral = c.neutralY; maxAbove = c.maxY; maxBelow = c.minY
            }
        } else {
            neutral = 0; maxAbove = 0; maxBelow = 0
        }
        let scaled: Int
        if neutral != 0 && maxAbove != 0 && maxBelow != 0 {
            let delta = Int(raw) - Int(neutral)
            if delta >= 0 {
                scaled = (delta * 127) / Int(maxAbove)
            } else {
                scaled = (delta * 127) / Int(maxBelow)
            }
        } else {
            scaled = (Int(raw) - 2048) >> 3
        }
        let signed = invert ? -scaled : scaled
        return Int8(clamping: signed)
    }
}

// FirmwareInfo lives alongside its parser since it's shared by every NS2 profile.
struct FirmwareInfo: Sendable, CustomStringConvertible {
    var controllerVersion: (UInt8, UInt8, UInt8)
    var controllerType: UInt8
    var bluetoothPatch: (UInt8, UInt8, UInt8)

    var typeName: String {
        switch controllerType {
        case 0x00: "JoyCon (L)"
        case 0x01: "JoyCon (R)"
        case 0x02: "Pro Controller"
        case 0x03: "GameCube"
        default:   String(format: "0x%02X", controllerType)
        }
    }

    var description: String {
        let (cM, cm, cp) = controllerVersion
        let (bM, bm, bp) = bluetoothPatch
        return "\(typeName) fw \(cM).\(cm).\(cp), BT patch \(bM).\(bm).\(bp)"
    }
}
