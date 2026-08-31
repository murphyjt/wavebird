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

    // Motion data: 18 bytes at offset 0x2A — 4B timestamp, 2B temperature,
    // then six Int16 LE (accelX, accelY, accelZ, gyroX, gyroY, gyroZ).
    //
    // Linear-axis swap (accel + gyro X/Y) follows the -90° about Z geometry
    // derived from SDL's switch.c and switch2.c remaps:
    //   NS1.X = +NS2.Y    NS1.Y = -NS2.X    NS1.Z = +NS2.Z
    //
    // Gyro and accel MUST use this same rotation. GCMotion's gravity and
    // attitude are sensor-fusion output: the filter integrates gyro and
    // corrects the drift against the accelerometer. Negating a single gyro
    // axis flips the transform's determinant to -1, making the gyro frame a
    // mirror of the accel frame — the two then disagree about that axis and
    // the fused attitude oscillates. Observed 2026-08-30 as roll visibly
    // bouncing in a first-person game while pitch and yaw looked correct.
    // Any future axis correction has to move BOTH gyro and accel to another
    // proper rotation; never negate one gyro axis alone.
    //
    // Axis semantics, from SDL_hidapi_switch.c's sensor remap (SDL X/pitch =
    // -rawY, Y/yaw = +rawZ, Z/roll = -rawX): in the NS1 frame emitted here
    // gyroX is roll, gyroY is pitch, gyroZ is yaw.
    //
    // Gyro Z (yaw) previously carried an extra negation, on the reasoning that
    // Apple's NS1 driver inverts yaw. That was measured 2026-05-17, one day
    // after the bad factory IMU calibration blob landed (see SwitchProSession
    // 0x6020) and while gyro Z's SDL-reading scale denominator was negative —
    // i.e. against an already-inverted axis. Zeroing the origins removed the
    // inversion and left the compensation stranded, which is why yaw read
    // backwards until it was dropped.
    //
    // Accel scale matches NS1 (~4096 LSB/g); gyro scale is within ~15% of
    // NS1's ~40 rad/s full range so we pass through unscaled. Returns nil
    // when the slot is all zeros — IMU disabled or feature bit not yet
    // enabled.
    //
    // AXIS MAPPING VERIFIED ON HARDWARE 2026-08-31. Measured with
    // Tools/NS1Dump.swift (`imu` against a real NS1 Pro, `imu virtual` against
    // what we emit), gravity in raw report-0x30 counts, ~4096 = 1g:
    //
    //   orientation      real NS1 Pro         NS2 Pro (ours)      GameCube (ours)
    //   flat, face up    (-724, +68, +4092)   (-722,  -3, +4116)  (-123, +14, +4133)
    //   left edge down   ( +11, -4033, +423)  (+136, -4076, +376) (+280, -4100, -78)
    //   nose down        (-4048, +152, -404)  (X pinned by flat)  (-4100, +92, -194)
    //
    // Same axis, same sign, ~1g in every case, across two different shells.
    // The differing flat X term is resting tilt, not axes: a Pro sits ~10 deg
    // off vertical, a GameCube ~1.7 deg.
    //
    // Measure this at the WIRE level only. GCMotion applies its own
    // undocumented remap, and comparing its output against raw values made a
    // correct frame look 90 deg wrong for most of a debugging session.
    static func parseIMU(_ slice: Data) -> IMUSample? {
        let i = slice.startIndex + 6
        guard slice.endIndex - i >= 12 else { return nil }
        let ax = readInt16LE(slice, at: i)
        let ay = readInt16LE(slice, at: i + 2)
        let az = readInt16LE(slice, at: i + 4)
        let gx = readInt16LE(slice, at: i + 6)
        let gy = readInt16LE(slice, at: i + 8)
        let gz = readInt16LE(slice, at: i + 10)
        if ax == 0 && ay == 0 && az == 0 && gx == 0 && gy == 0 && gz == 0 { return nil }
        return IMUSample(
            accelX: ay,
            accelY: negSat(ax),
            accelZ: az,
            gyroX:  gy,           // roll
            gyroY:  negSat(gx),   // pitch
            gyroZ:  gz            // yaw
        )
    }

    private static func readInt16LE(_ data: Data, at i: Data.Index) -> Int16 {
        Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i + 1]) << 8))
    }

    private static func negSat(_ v: Int16) -> Int16 {
        v == .min ? .max : -v
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
