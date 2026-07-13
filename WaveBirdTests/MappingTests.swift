import Foundation
import Testing
@testable import WaveBird

// Wire-bit decoding for the buttons added by the mapping-profiles feature.
// Bit positions from ndeadly hid_reports.md, Input Report 0x05 → Button Format
// (byte 3: 0x01 = GR, 0x02 = GL; byte 0: 0x10 = SR Right, 0x20 = SL Right;
// byte 2: 0x10 = SR Left, 0x20 = SL Left). Unverified on hardware as of
// 2026-07-12 — see the hardware checklist in the plan.
struct ButtonBitTests {

    @Test func proDecodesGLAndGR() {
        #expect(NS2ButtonBits.decode(1 << 24, table: NS2ButtonBits.pro) == [.gr])
        #expect(NS2ButtonBits.decode(1 << 25, table: NS2ButtonBits.pro) == [.gl])
    }

    @Test func joyConRDecodesSLAndSR() {
        #expect(NS2ButtonBits.decode(1 << 4, table: NS2ButtonBits.joyConR) == [.sr])
        #expect(NS2ButtonBits.decode(1 << 5, table: NS2ButtonBits.joyConR) == [.sl])
    }

    @Test func joyConLDecodesSLAndSR() {
        #expect(NS2ButtonBits.decode(1 << 20, table: NS2ButtonBits.joyConL) == [.sr])
        #expect(NS2ButtonBits.decode(1 << 21, table: NS2ButtonBits.joyConL) == [.sl])
    }

    @Test func fullReportFrameCarriesGrips() {
        // Button field is bytes 4..7 of report 0x05; GL/GR live in byte 7.
        var frame = Data(repeating: 0, count: 62)
        frame[7] = 0x03
        let decoded = NS2Report0x05.decode(frame)
        #expect(decoded != nil)
        let buttons = NS2ButtonBits.decode(decoded!.buttonBits, table: NS2ButtonBits.pro)
        #expect(buttons.contains(.gl))
        #expect(buttons.contains(.gr))
    }
}
