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
