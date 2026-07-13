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

struct PhysicalButtonTests {

    @Test func rawValuesRoundTrip() {
        for button in PhysicalButton.allCases {
            #expect(PhysicalButton(rawValue: button.rawValue) == button)
        }
    }

    @Test func reservedSentinelsDontCollide() {
        // The editor picker tags "default" and "off" alongside raw values.
        #expect(PhysicalButton(rawValue: "off") == nil)
        #expect(PhysicalButton(rawValue: "default") == nil)
    }

    @Test func gripAndRailMembersMatch() {
        #expect(PhysicalButton.gl.buttonSetMember == .gl)
        #expect(PhysicalButton.gr.buttonSetMember == .gr)
        #expect(PhysicalButton.sl.buttonSetMember == .sl)
        #expect(PhysicalButton.sr.buttonSetMember == .sr)
    }

    @Test func mappingChoiceRawValues() {
        #expect(MappingChoice.off.rawValue == "off")
        #expect(MappingChoice.physical(.gl).rawValue == "gl")
        #expect(MappingChoice(rawValue: "off") == .off)
        #expect(MappingChoice(rawValue: "zl") == .physical(.zl))
        #expect(MappingChoice(rawValue: "nonsense") == nil)
    }
}

struct MappingControlsTests {

    @Test func everyShippingModeHasACatalog() {
        for modeID in HIDOutputCatalog.allowListIDs {
            #expect(!MappingControls.controls(forModeID: modeID).isEmpty,
                    "no control catalog for \(modeID)")
        }
    }

    @Test func controlIDsAreUniqueAndModePrefixed() {
        for modeID in HIDOutputCatalog.allowListIDs {
            let ids = MappingControls.controls(forModeID: modeID).map(\.id)
            #expect(Set(ids).count == ids.count)
            #expect(ids.allSatisfy { $0.hasPrefix("\(modeID).") })
        }
    }

    @Test func debugOnlyModesHaveNoCatalog() {
        // Passthrough bypasses buildReport entirely; mapping is meaningless there.
        #expect(MappingControls.controls(forModeID: "ns2Passthrough").isEmpty)
    }
}
