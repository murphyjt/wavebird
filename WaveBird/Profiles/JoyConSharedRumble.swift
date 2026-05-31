import Foundation

// Single-LRA HD rumble encoder shared by the L and R Joy-Con profiles.
//
// JoyCon 2 Output Report 0x01 (42 bytes total, BLE handle 0x0012):
//   byte[0]      = 0x00 (BT report ID)
//   byte[1]      = state byte: enable[6] | ops_cnt[5:4] | tid[3:0]
//   bytes[2..6]  = LRA op (5 bytes) — same packed layout as Pro
//   bytes[7..16] = padding (10 bytes); together with the state byte this fills
//                  the 16-byte "HD Rumble Data" slot defined in hid_reports.md
//   bytes[17..41]= reserved
//
// Per-op layout matches darthcloud's sw2_lra_op_t (see ProControllerProfile):
//   32-bit val with lf_freq[8:0] | lf_amp[19:10] | hf_freq[28:20] | enable[31]
//   + separate 8-bit hf_amp byte at byte 4.
enum JoyConSharedRumble {
    static func encode(
        amp: UInt16,
        freqOverride: UInt16?,
        hiFreq: UInt16,
        loFreq: UInt16,
        hiAmpScale: Double,
        loAmpScale: Double,
        intensity: Double,
        sequence: UInt8
    ) -> Data? {
        let isStop = amp == 0
        if intensity == 0 && !isStop { return nil }

        let scaledAmp = UInt16(Double(amp) * intensity)
        let hf = RumbleSettings.clampFreq(freqOverride ?? hiFreq)
        let lf = RumbleSettings.clampFreq(freqOverride ?? loFreq)
        let hfAmp = scaledByte(amp: scaledAmp, scale: hiAmpScale)
        let lfAmp = scaledTen( amp: scaledAmp, scale: loAmpScale)
        let active = scaledAmp > 0

        let tid = sequence & 0xF
        let op = packLRAOp(hfFreq: hf, hfAmp: hfAmp, lfFreq: lf, lfAmp: lfAmp, enable: active)

        var packet = Data(count: 42)
        packet[0] = 0x00
        packet[1] = (active ? 0x50 : 0x10) | tid
        for i in 0..<5 { packet[2 + i] = op[i] }
        return packet
    }

    private static func scaledByte(amp: UInt16, scale: Double) -> UInt8 {
        let v = Double(amp) * scale * 255.0 / Double(UInt16.max)
        return UInt8(min(max(v, 0), 255))
    }

    private static func scaledTen(amp: UInt16, scale: Double) -> UInt16 {
        let v = Double(amp) * scale * 1023.0 / Double(UInt16.max)
        return UInt16(min(max(v, 0), 1023))
    }

    private static func packLRAOp(
        hfFreq: UInt16, hfAmp: UInt8,
        lfFreq: UInt16, lfAmp: UInt16,
        enable: Bool
    ) -> [UInt8] {
        let val: UInt32 =
              (UInt32(lfFreq) & 0x1FF)
            | ((UInt32(lfAmp) & 0x3FF) << 10)
            | ((UInt32(hfFreq) & 0x1FF) << 20)
            | ((enable ? UInt32(1) : 0) << 31)
        return [
            UInt8( val        & 0xFF),
            UInt8((val >>  8) & 0xFF),
            UInt8((val >> 16) & 0xFF),
            UInt8((val >> 24) & 0xFF),
            hfAmp,
        ]
    }
}
