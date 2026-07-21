import Foundation
import Testing
@testable import WaveBird

struct ProfileColorTests {
    @Test func rawValuesRoundTrip() {
        for color in ProfileColor.allCases {
            #expect(ProfileColor(rawValue: color.rawValue) == color)
        }
    }

    @Test func automaticIsFirstAndPaletteIsUniqueSixteen() {
        #expect(ProfileColor.allCases.first == .automatic)
        #expect(ProfileColor.allCases.count == 16)
        let raws = ProfileColor.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
    }

    @Test func unknownRawValueIsNil() {
        #expect(ProfileColor(rawValue: "chartreuse-glow") == nil)
    }
}

struct ProfileSymbolTests {
    @Test func quickIsSubsetOfAllAndUnique() {
        #expect(Set(ProfileSymbol.quick).isSubset(of: Set(ProfileSymbol.all)))
        #expect(Set(ProfileSymbol.all).count == ProfileSymbol.all.count)
    }

    @Test func defaultsCoverShippingBaseModes() {
        #expect(ProfileSymbol.defaultAppearance(forBaseModeID: "xboxSeries").color == .green)
        #expect(ProfileSymbol.defaultAppearance(forBaseModeID: "dualShock4").symbol == "playstation.logo")
        #expect(ProfileSymbol.defaultAppearance(forBaseModeID: "dualSense").symbol == "playstation.logo")
        #expect(ProfileSymbol.defaultAppearance(forBaseModeID: "switchPro").color == .red)
        // Unknown base mode still yields a usable fallback, never crashes.
        #expect(!ProfileSymbol.defaultAppearance(forBaseModeID: "mystery").symbol.isEmpty)
    }
}

struct ProfileAppearanceResolveTests {
    @Test func oldBlobWithoutAppearanceDecodesToNil() throws {
        // A pre-appearance custom-profile blob has no symbolName/colorID keys.
        let json = """
        {"id":"abc","name":"Legacy","baseModeID":"xboxSeries","mapping":{}}
        """
        let profile = try JSONDecoder().decode(MappingProfile.self, from: Data(json.utf8))
        #expect(profile.symbolName == nil)
        #expect(profile.colorID == nil)
    }

    @Test func resolveFallsBackToBaseDefault() {
        let bare = MappingProfile(id: "x", name: "Bare", baseModeID: "xboxSeries")
        let a = ProfileAppearance.resolve(bare)
        #expect(a.symbolName == "xbox.logo")
        #expect(a.tint == .green)
    }

    @Test func resolveHonorsExplicitChoice() {
        let custom = MappingProfile(id: "y", name: "Mine", baseModeID: "switchPro",
                                    symbolName: "flame.fill", colorID: "purple")
        let a = ProfileAppearance.resolve(custom)
        #expect(a.symbolName == "flame.fill")
        #expect(a.tint == .purple)
    }

    @Test func resolveIgnoresUnknownColorID() {
        let custom = MappingProfile(id: "z", name: "Bad", baseModeID: "switchPro", colorID: "not-a-color")
        #expect(ProfileAppearance.resolve(custom).tint == .red)  // base default
    }
}

struct MappingControlSymbolsTests {
    @Test func faceButtonsMapToGlyphs() {
        #expect(MappingControlSymbols.symbol(forControlID: "xboxSeries.a") == "a.circle")
        #expect(MappingControlSymbols.symbol(forControlID: "switchPro.y") == "y.circle")
        #expect(MappingControlSymbols.symbol(forControlID: "dualShock4.cross") == "xmark.circle")
        #expect(MappingControlSymbols.symbol(forControlID: "dualSense.triangle") == "triangle.circle")
    }

    @Test func xboxSystemButtonsMapToGlyphs() {
        #expect(MappingControlSymbols.symbol(forControlID: "xboxSeries.view") == "rectangle.on.rectangle")
        #expect(MappingControlSymbols.symbol(forControlID: "xboxSeries.menu") == "line.3.horizontal")
        #expect(MappingControlSymbols.symbol(forControlID: "xboxSeries.guide") == "xbox.logo")
        #expect(MappingControlSymbols.symbol(forControlID: "xboxSeries.share") == "square.and.arrow.up")
    }

    @Test func playStationSystemButtonsMapToGlyphs() {
        #expect(MappingControlSymbols.symbol(forControlID: "dualShock4.circle") == "circle.circle")
        #expect(MappingControlSymbols.symbol(forControlID: "dualShock4.square") == "square.circle")
        #expect(MappingControlSymbols.symbol(forControlID: "dualShock4.options") == "line.3.horizontal")
        #expect(MappingControlSymbols.symbol(forControlID: "dualShock4.ps") == "playstation.logo")
        #expect(MappingControlSymbols.symbol(forControlID: "dualSense.create") == "square.and.arrow.up")
        #expect(MappingControlSymbols.symbol(forControlID: "dualSense.ps") == "playstation.logo")
    }

    @Test func unmappedControlFallsBackToNil() {
        #expect(MappingControlSymbols.symbol(forControlID: "dualShock4.touchpad") == nil)
        #expect(MappingControlSymbols.symbol(forControlID: "whatever.zzz") == nil)
    }
}
