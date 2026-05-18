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
