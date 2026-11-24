import Foundation

// Experimental console-channel support, verified against joycon2android's
// ConsoleCommands / ConsolePacketParser (b70046d, PR #26). These are protocol
// facts, not Android's SMP/L2CAP workarounds, which don't apply to CoreBluetooth.
enum NS2Console {
    static let prefixLength = 17

    static func frame(_ command: Data) -> Data {
        Data(repeating: 0, count: prefixLength) + command
    }

    static func command(_ id: UInt8, _ sub: UInt8, _ payload: [UInt8] = []) -> Data {
        Data([id, 0x91, 1, sub, 0, UInt8(payload.count), 0, 0] + payload)
    }

    static func spiRead(_ address: UInt32, length: UInt8) -> Data {
        command(2, 4, [length, 0x7E, 0, 0] + (0..<4).map {
            UInt8(truncatingIfNeeded: address >> ($0 * 8))
        })
    }

    static let initCommands: [Data] = [
        NS2Commands.handshake,
        spiRead(0x13000, length: 0x40),
        NS2Commands.firmwareInfo,
        command(0x16, 1),
        NS2Commands.connectionVibration,
        NS2Commands.player1LED,
        command(0x0C, 2, [0x37, 0, 0, 0]),
        spiRead(0x13080, length: 0x40),
        spiRead(0x1FC040, length: 0x40),
        spiRead(0x13040, length: 0x10),
        spiRead(0x13100, length: 0x18),
        command(0x11, 3),
        spiRead(0x13060, length: 0x20),
        command(0x0A, 8, [1, 0x59, 9, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF,
                          0x35, 0, 0x46, 0, 0, 0, 0, 0, 0, 0, 0]),
        command(0x11, 1),
        command(0x0C, 4, [0x37, 0, 0, 0]),
    ]

    // Console replies may have a prefix. Normalize the header before passing
    // it to the existing metadata parsers. SPI address matching rejects a late
    // reply to a previous read with the same command/subcommand.
    static func reply(_ value: Data, to request: Data, console: Bool) -> Data? {
        guard request.count >= 4, value.count >= 8 else { return nil }
        let bytes = Array(value)
        for offset in 0...(console ? bytes.count - 8 : 0) {
            guard bytes[offset] == request[request.startIndex], bytes[offset + 1] == 1,
                  bytes[offset + 3] == request[request.startIndex + 3] else { continue }
            let result = Data(bytes.dropFirst(offset))
            if request.first == 2, request[request.startIndex + 3] == 4 {
                guard request.count >= 16, result.count >= 16,
                      result.suffix(from: 12).prefix(4) == request.suffix(from: request.startIndex + 12).prefix(4)
                else { continue }
            }
            return result
        }
        return nil
    }

    // Translate only buttons + stick to WaveBird's shared Report 0x05 layout.
    // Byte 4 here is the *first* button byte (Android's uint32 starts at 3).
    // No invented motion values: NYXI's console motion is not the shared IMU.
    static func sharedReport(_ data: Data, left: Bool) -> Data? {
        guard data.count >= 8 else { return nil }
        let b = data.startIndex
        guard data[b + 4] == 7 else { return nil }
        let raw = UInt16(data[b + 2]) | UInt16(data[b + 3]) << 8
        let map: [(Int, Int)] = left
            ? [(0,16), (1,18), (2,19), (3,17), (4,22), (5,23),
               (6,8), (7,11), (8,13), (14,20), (15,21)]
            : [(0,2), (1,3), (2,0), (3,1), (4,6), (5,7),
               (6,9), (7,10), (8,12), (12,14), (14,4), (15,5)]
        var buttons: UInt32 = 0
        for (source, target) in map where raw & (1 << source) != 0 {
            buttons |= 1 << target
        }
        var report = Data(repeating: 0, count: 63)
        report[0] = data[b]
        for i in 0..<4 { report[4 + i] = UInt8(truncatingIfNeeded: buttons >> (i * 8)) }
        let stickOffset = left ? 10 : 13
        report.replaceSubrange(stickOffset..<(stickOffset + 3), with: data[(b + 5)..<(b + 8)])
        return report
    }
}
