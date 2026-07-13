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

struct MappingTransformTests {

    private func state(buttons: ButtonSet, shoulders: StandardShoulders = StandardShoulders()) -> ControllerState {
        var s = ControllerState.zero
        s.buttons = buttons
        s.shoulders = shoulders
        s.leftStick = SIMD2(100, -200)
        return s
    }

    @Test func identitySpecIsUntouchedPassthrough() {
        let input = state(buttons: [.a, .zl, .gl],
                          shoulders: StandardShoulders(leftBumper: true, leftTriggerAnalog: 0x80))
        let out = input.applyingMapping(.identity)
        #expect(out.buttons == input.buttons)
        #expect(out.shoulders == input.shoulders)
        #expect(out.leftStick == input.leftStick)
    }

    @Test func glDrivesRemappedButton() {
        // "Xbox A ← GL": Xbox A's driver is ButtonSet.b.
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.b), source: .physical(.gl))
        ])
        let pressed = state(buttons: [.gl]).applyingMapping(spec)
        #expect(pressed.buttons.contains(.b))
        // The physical B button no longer drives the remapped control.
        let bOnly = state(buttons: [.b]).applyingMapping(spec)
        #expect(!bOnly.buttons.contains(.b))
        // GL itself passes through untouched (it drives no default control).
        #expect(pressed.buttons.contains(.gl))
    }

    @Test func glDrivesTriggerAsDigitalFullPull() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .leftTrigger, source: .physical(.gl))
        ])
        let pressed = state(buttons: [.gl]).applyingMapping(spec)
        #expect(pressed.shoulders.leftTriggerDigital)
        #expect(pressed.shoulders.leftTriggerAnalog == 0xFF)
        // Original trigger source is cleared when the row is remapped.
        let zl = state(buttons: [.zl],
                       shoulders: StandardShoulders(leftTriggerDigital: true, leftTriggerAnalog: 0xFF))
            .applyingMapping(spec)
        #expect(!zl.shoulders.leftTriggerDigital)
        #expect(zl.shoulders.leftTriggerAnalog == 0)
    }

    @Test func offSuppressesControl() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.home), source: .off)
        ])
        let out = state(buttons: [.home]).applyingMapping(spec)
        #expect(!out.buttons.contains(.home))
    }

    @Test func defaultRowsPreserveAnalogTriggers() {
        // Non-default spec elsewhere; the LT row is untouched, so GC's analog
        // trigger value copies through.
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.b), source: .physical(.gl))
        ])
        let out = state(buttons: [],
                        shoulders: StandardShoulders(leftTriggerAnalog: 0x80)).applyingMapping(spec)
        #expect(out.shoulders.leftTriggerAnalog == 0x80)
    }

    @Test func multiMemberDriverClearsAndSetsTogether() {
        // Xbox Menu reads .plus OR .start; remapping it must silence both.
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons([.plus, .start]), source: .physical(.gr))
        ])
        let startOnly = state(buttons: [.start]).applyingMapping(spec)
        #expect(!startOnly.buttons.contains(.start))
        #expect(!startOnly.buttons.contains(.plus))
        let grPressed = state(buttons: [.gr]).applyingMapping(spec)
        #expect(grPressed.buttons.contains(.plus))
        #expect(grPressed.buttons.contains(.start))
    }

    @Test func onePhysicalButtonMayDriveSeveralControls() {
        let spec = ResolvedMappingSpec(overrides: [
            .init(driver: .buttons(.b), source: .physical(.gl)),
            .init(driver: .rightBumper, source: .physical(.gl)),
        ])
        let out = state(buttons: [.gl]).applyingMapping(spec)
        #expect(out.buttons.contains(.b))
        #expect(out.shoulders.rightBumper)
    }
}

struct MappingProfileTests {

    @Test func roundTripsThroughJSON() throws {
        let profile = MappingProfile(
            id: UUID().uuidString,
            name: "Grips as bumpers",
            baseModeID: "xboxSeries",
            mapping: ["xboxSeries.leftBumper": .physical(.gl),
                      "xboxSeries.guide": .off]
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(MappingProfile.self, from: data)
        #expect(decoded == profile)
    }

    @Test func defaultProfileResolvesToIdentity() {
        let profile = MappingProfile(id: MappingProfile.defaultProfileID(forModeID: "xboxSeries"),
                                     name: "Xbox Wireless Controller",
                                     baseModeID: "xboxSeries",
                                     mapping: [:])
        #expect(profile.isBuiltIn)
        #expect(ResolvedMappingSpec.resolve(profile: profile).isDefault)
    }

    @Test func customMappingResolvesOverrides() {
        let profile = MappingProfile(
            id: UUID().uuidString,
            name: "Test",
            baseModeID: "xboxSeries",
            mapping: ["xboxSeries.a": .physical(.gl),
                      "xboxSeries.guide": .off,
                      "xboxSeries.unknownRow": .physical(.gr)]  // stale ID: ignored
        )
        let spec = ResolvedMappingSpec.resolve(profile: profile)
        #expect(spec.overrides.count == 2)
    }

    @Test func mappingChoiceEncodesAsBareJSONString() throws {
        // The store's on-disk format depends on MappingChoice serializing as
        // its raw string (stdlib RawRepresentable Codable path), not SE-0295
        // keyed form like {"physical":"gl"}.
        #expect(String(data: try JSONEncoder().encode(MappingChoice.physical(.gl)), encoding: .utf8) == "\"gl\"")
        #expect(String(data: try JSONEncoder().encode(MappingChoice.off), encoding: .utf8) == "\"off\"")
    }
}

@MainActor
struct MappingProfileStoreTests {

    private func makeStore() -> MappingProfileStore {
        let defaults = UserDefaults(suiteName: "MappingProfileStoreTests")!
        defaults.removePersistentDomain(forName: "MappingProfileStoreTests")
        return MappingProfileStore(defaults: defaults)
    }

    @Test func builtInsCoverShippingModes() {
        let store = makeStore()
        let ids = Set(store.builtInProfiles.map(\.baseModeID))
        #expect(HIDOutputCatalog.allowListIDs.isSubset(of: ids))
        #expect(store.builtInProfiles.allSatisfy { $0.isBuiltIn && $0.mapping.isEmpty })
    }

    @Test func upsertPersistsAndReloads() {
        let defaults = UserDefaults(suiteName: "MappingProfileStoreTests")!
        defaults.removePersistentDomain(forName: "MappingProfileStoreTests")
        let store = MappingProfileStore(defaults: defaults)
        let profile = MappingProfile(id: UUID().uuidString, name: "Mine",
                                     baseModeID: "dualSense",
                                     mapping: ["dualSense.l2": .physical(.gl)])
        store.upsert(profile)
        let reloaded = MappingProfileStore(defaults: defaults)
        #expect(reloaded.profile(id: profile.id) == profile)
    }

    @Test func corruptRecordIsDroppedOthersSurvive() throws {
        let defaults = UserDefaults(suiteName: "MappingProfileStoreTests")!
        defaults.removePersistentDomain(forName: "MappingProfileStoreTests")
        let good = MappingProfile(id: "good-id", name: "Good", baseModeID: "switchPro", mapping: [:])
        let dict: [String: Data] = [
            "good-id": try JSONEncoder().encode(good),
            "bad-id": Data("not json".utf8),
        ]
        defaults.set(dict, forKey: MappingProfileStore.defaultsKey)
        let store = MappingProfileStore(defaults: defaults)
        #expect(store.customProfiles.count == 1)
        #expect(store.profile(id: "good-id") != nil)
    }

    @Test func deleteReturnsBaseDefaultFallback() {
        let store = makeStore()
        let profile = MappingProfile(id: UUID().uuidString, name: "Doomed",
                                     baseModeID: "xboxSeries", mapping: [:])
        store.upsert(profile)
        let fallback = store.delete(id: profile.id)
        #expect(fallback == "default.xboxSeries")
        #expect(store.profile(id: profile.id) == nil)
        #expect(store.delete(id: "never-existed") == nil)
    }

    @Test func bareLegacyModeIDResolvesToDefaultProfile() {
        let store = makeStore()
        let profile = store.profile(id: "xboxSeries")
        #expect(profile?.id == "default.xboxSeries")
        #expect(profile?.baseModeID == "xboxSeries")
    }
}
