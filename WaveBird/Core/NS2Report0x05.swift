import Foundation

// Shared decoder for NS2's Report 0x05 input frame. The wire layout is the
// same across Pro / GC / Joy-Con — each controller just populates a subset of
// the fields. This stage produces raw primitives (button bitfield, packed
// stick pairs, trigger bytes); profiles map those onto their own ButtonSet
// view via NS2ButtonBits + a per-profile table.
enum NS2Report0x05 {
    struct Decoded {
        var buttonBits: UInt32
        var leftStickRaw: (UInt16, UInt16)
        var rightStickRaw: (UInt16, UInt16)
        var rawTriggerL: UInt8
        var rawTriggerR: UInt8
        // Slice covering the IMU block at offset 0x2A (used by Pro;
        // ignored elsewhere). Empty if the input is too short.
        var imuSlice: Data
    }

    static func decode(_ data: Data, offset: Int = 0) -> Decoded? {
        guard data.count - offset >= 62 else { return nil }
        let base = data.startIndex.advanced(by: offset)
        let imuEnd = min(data.endIndex, base + 0x2A + 24)
        return Decoded(
            buttonBits:
                  UInt32(data[base + 4])
                | (UInt32(data[base + 5]) << 8)
                | (UInt32(data[base + 6]) << 16)
                | (UInt32(data[base + 7]) << 24),
            leftStickRaw:  NS2Sticks.unpack(data, at: base + 10),
            rightStickRaw: NS2Sticks.unpack(data, at: base + 13),
            rawTriggerL:   data[base + 60],
            rawTriggerR:   data[base + 61],
            imuSlice:      data[(base + 0x2A)..<imuEnd]
        )
    }
}

// One canonical bit→ButtonSet table per controller layout. Two real
// disagreements between layouts: bit 7 (GC = Z, Pro/JC = ZR) and bit 9
// (GC = start, Pro/JC = plus). Everything else is shared.
enum NS2ButtonBits {
    struct Entry {
        let bit: Int
        let button: ButtonSet
        init(_ bit: Int, _ button: ButtonSet) {
            self.bit = bit
            self.button = button
        }
    }

    static let gameCube: [Entry] = [
        Entry(0, .y), Entry(1, .x), Entry(2, .b), Entry(3, .a),
        Entry(6, .r), Entry(7, .z),
        Entry(9, .start),
        Entry(12, .home), Entry(13, .capture), Entry(14, .c),
        Entry(16, .dpadDown), Entry(17, .dpadUp), Entry(18, .dpadRight), Entry(19, .dpadLeft),
        Entry(22, .l), Entry(23, .zl),
    ]

    static let pro: [Entry] = [
        Entry(0, .y), Entry(1, .x), Entry(2, .b), Entry(3, .a),
        Entry(6, .r), Entry(7, .zr),
        Entry(8, .minus), Entry(9, .plus), Entry(10, .stickR), Entry(11, .stickL),
        Entry(12, .home), Entry(13, .capture), Entry(14, .c),
        Entry(16, .dpadDown), Entry(17, .dpadUp), Entry(18, .dpadRight), Entry(19, .dpadLeft),
        Entry(22, .l), Entry(23, .zl),
        // Rear grip buttons GL/GR — byte 3 of the button field, 0x02/0x01.
        // Source: ndeadly hid_reports.md (Report 0x05 Button Format).
        // Unverified on hardware as of 2026-07-12.
        Entry(24, .gr), Entry(25, .gl),
    ]

    static let joyConL: [Entry] = [
        Entry(8, .minus), Entry(11, .stickL), Entry(13, .capture),
        Entry(16, .dpadDown), Entry(17, .dpadUp), Entry(18, .dpadRight), Entry(19, .dpadLeft),
        Entry(22, .l), Entry(23, .zl),
        // Side-rail SL/SR (Left Joy-Con) — byte 2, 0x20/0x10 per ndeadly
        // hid_reports.md. Unverified on hardware as of 2026-07-12.
        Entry(20, .sr), Entry(21, .sl),
    ]

    static let joyConR: [Entry] = [
        Entry(0, .y), Entry(1, .x), Entry(2, .b), Entry(3, .a),
        Entry(6, .r), Entry(7, .zr),
        Entry(9, .plus), Entry(10, .stickR),
        Entry(12, .home), Entry(14, .c),
        // Side-rail SL/SR (Right Joy-Con) — byte 0, 0x20/0x10 per ndeadly
        // hid_reports.md. Unverified on hardware as of 2026-07-12.
        Entry(4, .sr), Entry(5, .sl),
    ]

    static func decode(_ bits: UInt32, table: [Entry]) -> ButtonSet {
        var out: ButtonSet = []
        for entry in table where (bits >> entry.bit) & 1 != 0 {
            out.insert(entry.button)
        }
        return out
    }
}
