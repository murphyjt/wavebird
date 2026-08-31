import CoreHID
import Foundation

// Sony DualSense (CFI-ZCT1, VID 0x054C / PID 0x0CE6). Report ID 0x01 matches
// the real USB input report: 63 bytes of payload plus the leading report ID.
//
// Report (64 bytes including ID):
//   0:    Report ID (0x01)
//   1..4: LX, LY, RX, RY (UInt8 0..255)
//   5:    L2 analog
//   6:    R2 analog
//   7:    sequence / vendor byte (left at 0)
//   8:    hat low nibble | face buttons high nibble (same shape as DS4)
//   9:    L1=0, R1=1, L2=2, R2=3, CREATE=4, OPTIONS=5, L3=6, R3=7
//   10:   PS=0, TPad=1, Mute=2, vendor bits 3..7
//   11..63: vendor-defined fields, left at 0
struct DualSenseOutput: HIDOutputProfile, HIDOutputSession {
    let vendorID: UInt16 = 0x054C
    let productID: UInt16 = 0x0CE6
    let productName = "DualSense Wireless Controller"
    let manufacturer: String? = "Sony Interactive Entertainment"
    let versionNumber: UInt16 = 0x0100

    var descriptor: Data { Self.descriptorBytes }

    func makeSession(deviceSerial: String?) -> any HIDOutputSession { self }

    // macOS sends rumble as USB Output Report 0x02:
    //   [id, valid_flag0, valid_flag1, right_motor, left_motor, …haptic/lightbar]
    // valid_flag0 bit 0 = "compatible rumble emulation" (DS_OUTPUT_VALID_FLAG0_
    // COMPATIBLE_VIBRATION in Linux hid-playstation) — gates motor bytes [3..4].
    // Host already drives ~30 Hz frames during a haptic burst; we don't refresh
    // on our side, so when frames stop the NS2 motor times out naturally.
    func parseRumble(type: HIDReportType, id: HIDReportID?, data: Data) -> RumbleCommand? {
        guard type == .output, id?.rawValue == 0x02, data.count >= 5 else { return nil }
        let b = data.startIndex
        guard data[b + 1] & 0x01 != 0 else { return nil }
        // *257 spreads 0..255 evenly across 0..65535 (since 65535 = 255 * 257).
        return RumbleCommand(leftAmp: UInt16(data[b + 4]) * 257,
                             rightAmp: UInt16(data[b + 3]) * 257)
    }

    static let descriptorBytes: Data = Data([
        0x05, 0x01,
        0x09, 0x05,
        0xA1, 0x01,
        0x85, 0x01,        // Report ID (0x01)

        0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
        0x09, 0x33, 0x09, 0x34,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x06,
        0x81, 0x02,

        0x06, 0x00, 0xFF,
        0x09, 0x20,
        0x95, 0x01,
        0x81, 0x02,

        0x05, 0x01,
        0x09, 0x39,
        0x15, 0x00,
        0x25, 0x07,
        0x35, 0x00,
        0x46, 0x3B, 0x01,
        0x65, 0x14,
        0x75, 0x04,
        0x95, 0x01,
        0x81, 0x42,
        0x65, 0x00,

        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x0F,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x0F,
        0x81, 0x02,

        0x06, 0x00, 0xFF,
        0x09, 0x21,
        0x95, 0x0D,
        0x81, 0x02,

        0x06, 0x00, 0xFF,
        0x09, 0x22,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x34,
        0x81, 0x02,

        0xC0,
    ])

    func buildReport(_ state: ControllerState) async -> Data {
        let s = state.buttons
        let sh = state.shoulders
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0]  = 0x01  // Report ID
        bytes[1]  = PresentationEncode.stickX(state.leftStick.x)
        bytes[2]  = PresentationEncode.stickY(state.leftStick.y)
        bytes[3]  = PresentationEncode.stickX(state.rightStick.x)
        bytes[4]  = PresentationEncode.stickY(state.rightStick.y)
        bytes[5]  = sh.leftTriggerAnalog
        bytes[6]  = sh.rightTriggerAnalog
        bytes[7]  = 0  // counter

        let hat = PresentationEncode.hat(
            up: s.contains(.dpadUp),
            right: s.contains(.dpadRight),
            down: s.contains(.dpadDown),
            left: s.contains(.dpadLeft),
            neutral: 0x08
        )
        var b8: UInt8 = hat & 0x0F
        if s.contains(.y) { b8 |= 0x10 }
        if s.contains(.b) { b8 |= 0x20 }
        if s.contains(.a) { b8 |= 0x40 }
        if s.contains(.x) { b8 |= 0x80 }
        bytes[8] = b8

        var b9: UInt8 = 0
        if sh.leftBumper           { b9 |= 0x01 }  // L1
        if sh.rightBumper          { b9 |= 0x02 }  // R1
        if sh.leftTriggerDigital   { b9 |= 0x04 }  // L2
        if sh.rightTriggerDigital  { b9 |= 0x08 }  // R2
        if s.contains(.capture) || s.contains(.minus) { b9 |= 0x10 }  // CREATE
        if s.contains(.start)   || s.contains(.plus)  { b9 |= 0x20 }  // OPTIONS
        if s.contains(.stickL)     { b9 |= 0x40 }
        if s.contains(.stickR)     { b9 |= 0x80 }
        bytes[9] = b9

        // Motion, at the real DualSense packet offsets (SDL's
        // PS5StatePacketCommon_t, +1 for the report ID byte):
        //   gyro  X/Y/Z -> 16..21,  accel X/Y/Z -> 22..27, six Int16 LE.
        // These land inside the descriptor's vendor blocks, so macOS delivers
        // them.
        //
        // MEASURED 2026-08-31 — who actually consumes this:
        //   - SDL DOES. It parses report 0x01 motion at exactly these offsets
        //     (SDL_hidapi_ps5.c), and gyro works in an SDL game.
        //   - Apple's GameController driver does NOT. GCMotion advertises
        //     rotationRate and reports exactly zero on every axis, across 52
        //     polled samples, while correct values are provably on the wire (a
        //     raw HID dump decodes to 1.011 g on +Y with the pad lying flat).
        //     Answering the calibration feature report it asks for did not
        //     change this. The reason is unestablished; the remaining suspects
        //     are the other feature reads it makes (0x09, 0x0B, 0x20) or a
        //     parse path we have not found.
        // So this mode gives motion to SDL clients only. Do not judge it with a
        // GameController-based probe — that measures the path that does not
        // work.
        //
        // Two conversions are needed, because IMUSample is in Nintendo units
        // and the NS1 sensor frame.
        //
        // Frame: composed from SDL's own two sensor remaps. Switch maps
        // SDL.X = -raw.Y, SDL.Y = +raw.Z, SDL.Z = -raw.X, while PlayStation is
        // identity (SDL_hidapi_ps5.c feeds GyroX/Y/Z straight through), so
        //   DS.X = -NS.Y,  DS.Y = +NS.Z,  DS.Z = -NS.X
        // That is a proper rotation (determinant +1) and is applied to accel
        // and gyro alike — a single-axis negation would mirror one sensor
        // against the other and make fused attitude oscillate.
        // Sanity check: lying flat, NS reads mostly +Z, which maps to DS +Y —
        // and SDL's accel convention is +Y up. Consistent.
        //
        // Scale: without a calibration feature report the host falls back to
        // nominal units (SDL HIDAPI_DriverPS5_ApplyCalibrationData: gyro
        // value*64/1024, accel value/8192), i.e. 16 LSB per deg/s and 8192 LSB
        // per g. Nintendo gives 4096 LSB/g and 936/0x343B deg/s per LSB
        // (14.285 LSB per deg/s). Our VHID answers GetReport with empty data,
        // so that fallback is what a host will use.
        if let imu = state.imu {
            func put(_ v: Int, at i: Int) {
                let c = Int16(clamping: v)
                bytes[i] = UInt8(truncatingIfNeeded: UInt16(bitPattern: c))
                bytes[i + 1] = UInt8(truncatingIfNeeded: UInt16(bitPattern: c) >> 8)
            }
            func gyro(_ v: Int16) -> Int { Int((Double(v) * Self.gyroScale).rounded()) }
            func accel(_ v: Int16) -> Int { Int(v) * 2 }

            put(gyro(negated(imu.gyroY)),  at: 16)   // DS.X = -NS.Y
            put(gyro(imu.gyroZ),           at: 18)   // DS.Y = +NS.Z
            put(gyro(negated(imu.gyroX)),  at: 20)   // DS.Z = -NS.X
            put(accel(negated(imu.accelY)), at: 22)
            put(accel(imu.accelZ),          at: 24)
            put(accel(negated(imu.accelX)), at: 26)
        }

        var b10: UInt8 = 0
        if s.contains(.home) { b10 |= 0x01 }
        if s.contains(.c)    { b10 |= 0x02 }
        bytes[10] = b10
        return Data(bytes)
    }

    // 16 LSB per deg/s (DualSense nominal) / 14.285 LSB per deg/s (Nintendo).
    private static let gyroScale = 16.0 / (1.0 / (936.0 / Double(0x343B)))

    // Negate without overflowing on Int16.min.
    private func negated(_ v: Int16) -> Int16 { v == .min ? .max : -v }

    // Apple's DualSense driver reads four feature reports during init
    // (0x05 maxSize=41, 0x09, 0x0B, 0x20). 0x05 is the IMU calibration blob;
    // answering it empty left GCMotion advertising rotationRate while every
    // value stayed zero, even though correct motion bytes were on the wire.
    //
    // Layout from SDL_hidapi_ps5.c::HIDAPI_DriverPS5_LoadCalibrationData —
    // all Int16 LE after the report ID:
    //   1..6   gyro pitch/yaw/roll bias
    //   7..18  gyro pitch+/-, yaw+/-, roll+/-
    //   19..22 gyro speed +/-
    //   23..34 accel X+/-, Y+/-, Z+/-
    //
    // Chosen so the derived sensitivities come out at the nominal values our
    // report bytes are already scaled for, i.e. this blob is a no-op:
    //   gyro  = (speedPlus + speedMinus) * 1024 / (plus - minus)
    //         = 2048 * 1024 / 32768 = 64          (SDL's expected divisor)
    //   accel = 2 * 8192 / (plus - minus)
    //         = 16384 / 16384 = 1                  (likewise)
    // Zero bias, symmetric ranges. SDL rejects |bias| > 1024 or a sensitivity
    // more than 50% off those divisors, so staying exact keeps it accepted.
    func handleGetReport(type: HIDReportType, id: HIDReportID?, maxSize: Int) async -> Data? {
        guard type == .feature, id?.rawValue == 0x05 else { return nil }
        var out = [UInt8](repeating: 0, count: 41)
        out[0] = 0x05
        func put(_ v: Int16, at i: Int) {
            let u = UInt16(bitPattern: v)
            out[i] = UInt8(truncatingIfNeeded: u)
            out[i + 1] = UInt8(truncatingIfNeeded: u >> 8)
        }
        // 1..6 gyro bias: zero — we forward samples that already rest near zero.
        for axis in 0..<3 {                       // 7..18 gyro per-axis range
            put( 16384, at: 7 + axis * 4)
            put(-16384, at: 9 + axis * 4)
        }
        put(1024, at: 19)                         // gyro speed +
        put(1024, at: 21)                         // gyro speed -
        for axis in 0..<3 {                       // 23..34 accel per-axis range
            put( 8192, at: 23 + axis * 4)
            put(-8192, at: 25 + axis * 4)
        }
        return Data(out.prefix(max(0, min(maxSize, out.count))))
    }
}
