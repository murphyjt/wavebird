//
//  WaveBirdTests.swift
//  WaveBirdTests
//
//  Created by Joshua Murphy on 5/7/26.
//

import Foundation
import Testing
@testable import WaveBird

struct WaveBirdTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

}

// Stick pipeline: NS2 raw 12-bit → ControllerState centered 12-bit
// (-2047..2047, neutral 0) → per-presentation wire width. Guards the
// resolution mapping and the sign-flip class of bug (a full-deflection axis
// must land on a rail, never wrap to the opposite extreme).
struct StickMappingTests {

    // MARK: Input — NS2Sticks (raw 12-bit + calibration → centered 12-bit)

    @Test func uncalibratedAxisCentersAndReachesRails() {
        // No calibration → raw-2048 directly (raw is already 12-bit).
        #expect(NS2Sticks.axis(2048, nil, axis: .x) == 0)
        #expect(NS2Sticks.axis(4095, nil, axis: .x) == 2047)
        #expect(NS2Sticks.axis(0, nil, axis: .x) == -2047)   // clamped from -2048
    }

    @Test func yAxisInvertsForUpPositive() {
        // decode() inverts Y so "positive = up"; X passes through.
        #expect(NS2Sticks.axis(4095, nil, axis: .y, invert: true) == -2047)
        #expect(NS2Sticks.axis(2048, nil, axis: .y, invert: true) == 0)
    }

    @Test func calibrationNormalizesToFullScale() {
        // Asymmetric extents: above-center 1000, below-center 500.
        let cal = StickCalibration(neutralX: 2000, neutralY: 2000,
                                   maxX: 1000, maxY: 1000, minX: 500, minY: 500)
        #expect(NS2Sticks.axis(2000, cal, axis: .x) == 0)         // neutral
        #expect(NS2Sticks.axis(3000, cal, axis: .x) == 2047)      // full above
        #expect(NS2Sticks.axis(1500, cal, axis: .x) == -2047)     // full below (500 extent)
        #expect(NS2Sticks.axis(2500, cal, axis: .x) == 1023)      // half above
    }

    @Test func decodeProducesCenteredPair() {
        #expect(NS2Sticks.decode((2048, 2048), nil) == SIMD2<Int16>(0, 0))
    }

    // MARK: Output — PlayStation 8-bit (DS4 + DualSense share these)

    @Test func playstation8BitCentersAndReachesRails() {
        #expect(PresentationEncode.stickX(0) == 128)
        #expect(PresentationEncode.stickX(2047) == 255)
        #expect(PresentationEncode.stickX(-2047) == 0)
        // Y is inverted (HID positive = down).
        #expect(PresentationEncode.stickY(0) == 128)
        #expect(PresentationEncode.stickY(2047) == 1)
        #expect(PresentationEncode.stickY(-2047) == 255)
    }

    // MARK: Output — Switch Pro 12-bit full report (the original flip regression)

    // Unpack the 3-byte packed left stick from a Report 0x30 (bytes 6..8).
    private func leftStick12(_ report: Data) -> (UInt16, UInt16) {
        let b = report.startIndex
        let x = UInt16(report[b + 6]) | ((UInt16(report[b + 7]) & 0x0F) << 8)
        let y = (UInt16(report[b + 7]) >> 4) | (UInt16(report[b + 8]) << 4)
        return (x, y)
    }

    @Test func switchProFullDeflectionDoesNotWrap() async {
        let session = SwitchProSession()
        func state(_ s: SIMD2<Int16>) -> ControllerState {
            var st = ControllerState.zero
            st.leftStick = s
            return st
        }
        // Full forward (+Y, "up") and full back (-Y) must land on OPPOSITE rails,
        // never collapse to the same value — the bug had +full wrapping to 0.
        let up = leftStick12(await session.buildFullReport(state(SIMD2(0, 2047))))
        let down = leftStick12(await session.buildFullReport(state(SIMD2(0, -2047))))
        #expect(up.1 <= 1)        // build negates Y: +2047 → 1
        #expect(down.1 == 4095)   // -2047 → 4095
        // X rails too (no negation on X).
        let right = leftStick12(await session.buildFullReport(state(SIMD2(2047, 0))))
        let left = leftStick12(await session.buildFullReport(state(SIMD2(-2047, 0))))
        #expect(right.0 == 4095)
        #expect(left.0 <= 1)
    }
}

// LTK confirmation regression vectors. Numbers are the example request/response
// frames published in ndeadly's switch2_controller_research/commands.md §0x15.
// If any of these fail, the byte-reversal convention in NS2PairingFrames is
// drifting from the protocol and pairing will be rejected by the controller.
struct NS2PairingVectorTests {

    // From the §0x15/0x04 example request: bytes 9..24 of `15 91 01 04 00 11 00 00 …`.
    private let wireA1 = Data([
        0x35, 0x03, 0xe9, 0x29, 0x82, 0x87, 0x71, 0x24,
        0xbe, 0xa8, 0x0c, 0x66, 0x46, 0x15, 0x83, 0x4b,
    ])
    // From the §0x15/0x04 example response: bytes 9..24 of `15 01 01 04 10 78 00 00 01 …`.
    // commands.md also calls out B1 as a fixed device constant.
    private let wireB1 = Data([
        0x5c, 0xf6, 0xee, 0x79, 0x2c, 0xdf, 0x05, 0xe1,
        0xba, 0x2b, 0x63, 0x25, 0xc4, 0x1a, 0x5f, 0x10,
    ])
    // From the §0x15/0x02 example request.
    private let wireA2 = Data([
        0x6f, 0xc6, 0xdf, 0x8a, 0xd8, 0xfe, 0xdf, 0x15,
        0xbb, 0x8c, 0x15, 0xe9, 0x1f, 0x32, 0x05, 0x44,
    ])
    // From the §0x15/0x02 example response.
    private let wireB2 = Data([
        0x13, 0x4c, 0x97, 0xf5, 0x11, 0xb9, 0xb6, 0xdd,
        0x4d, 0x86, 0xfd, 0x40, 0xf5, 0x36, 0xe9, 0xed,
    ])

    @Test func ltkConfirmationMatchesPublishedVector() throws {
        // Mirror what NS2Pairing.run does: caller-side a1/a2 are pre-reversal,
        // wire is post-reversal, b1 = reverse(b1Wire).
        let myA1 = Data(wireA1.reversed())
        let myB1 = Data(wireB1.reversed())
        let myA2 = Data(wireA2.reversed())
        let myLTK = Data(zip(myA1, myB1).map { $0 ^ $1 })

        let computed = NS2PairingCrypto.aes128ECB(key: myLTK, block: myA2)
        #expect(computed == wireB2)
    }

    @Test func exchangeAddressesFrameMatchesPublishedExample() throws {
        // §0x15/0x01 example request: header + `00 02 81 eb 3a eb f1 48 80 eb 3a eb f1 48`.
        // Wire addresses are reversed, so the natural-order primary is 48:F1:EB:3A:EB:81,
        // and the secondary is the primary with its LSB decremented (per memory_layout.md).
        let primary   = Data([0x48, 0xF1, 0xEB, 0x3A, 0xEB, 0x81])
        let secondary = NS2Pairing.secondaryAddress(from: primary)
        let expectedSecondary = Data([0x48, 0xF1, 0xEB, 0x3A, 0xEB, 0x80])
        #expect(secondary == expectedSecondary)

        let frame = NS2PairingFrames.exchangeAddresses(primary: primary, secondary: secondary)
        let expected = Data([
            0x15, 0x91, 0x01, 0x01, 0x00, 0x0E, 0x00, 0x00,
            0x00, 0x02,
            0x81, 0xEB, 0x3A, 0xEB, 0xF1, 0x48,
            0x80, 0xEB, 0x3A, 0xEB, 0xF1, 0x48,
        ])
        #expect(frame == expected)
    }
}

// The emulated SPI flash is what Apple's Switch Pro driver reads to decide how
// to scale our IMU samples. Getting 0x6020 wrong doesn't fail to build, doesn't
// fail to connect, and doesn't stop motion appearing — it just makes every
// motion value quietly wrong, which is why it's pinned here.
struct SwitchProIMUCalibrationTests {

    private var factoryIMUCal: [UInt8] {
        [UInt8](SwitchProSession.spiFlash(address: 0x6020, length: 24))
    }

    private func int16LE(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8)
    }

    @Test func originsAreZeroSoTheHostAppliesNominalScale() {
        let cal = factoryIMUCal
        // Accel origin XYZ at 0..5, gyro origin XYZ at 12..17.
        for i in stride(from: 0, to: 6, by: 2) {
            #expect(int16LE(cal, i) == 0, "accel origin at \(i) must stay zero")
        }
        for i in stride(from: 12, to: 18, by: 2) {
            #expect(int16LE(cal, i) == 0, "gyro origin at \(i) must stay zero")
        }
    }

    @Test func sensitivityCoefficientsAreNintendoNominal() {
        let cal = factoryIMUCal
        for i in stride(from: 6, to: 12, by: 2) {
            #expect(int16LE(cal, i) == 0x4000)  // accel
        }
        for i in stride(from: 18, to: 24, by: 2) {
            #expect(int16LE(cal, i) == 0x343B)  // gyro
        }
    }

    // Reproduces SDL's LoadIMUCalibration arithmetic (SDL_hidapi_switch.c) and
    // checks it lands on SDL's own no-calibration defaults. A negative
    // denominator here is the specific bug this replaced: it flips the axis and
    // rescales it, which reads as a large constant drift at rest.
    @Test func derivedScalesMatchSDLDefaults() {
        let cal = factoryIMUCal
        let accelDenom = Float(int16LE(cal, 6)) - Float(int16LE(cal, 0))
        let gyroDenom  = Float(int16LE(cal, 18)) - Float(int16LE(cal, 12))
        #expect(accelDenom > 0)
        #expect(gyroDenom > 0)

        // SWITCH_ACCEL_SCALE_MULT 4.0 / denom  ==  1 / SWITCH_ACCEL_SCALE 4096
        #expect(abs(4.0 / accelDenom - 1.0 / 4096.0) < 1e-9)
        // SWITCH_GYRO_SCALE_MULT 936.0 / denom  ==  1 / SWITCH_GYRO_SCALE 14.2842.
        // SDL rounds those two constants independently, so they agree to ~0.007%
        // rather than exactly; the tolerance is sized to that, not to float error.
        #expect(abs(936.0 / gyroDenom - 1.0 / 14.2842) < 1e-5)
    }
}
