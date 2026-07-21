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
