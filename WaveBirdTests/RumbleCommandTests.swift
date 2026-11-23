import Testing
@testable import WaveBird

// A solo Joy-Con plays a stereo command on one motor; its encoder reads only
// its own side, so the command is folded before it gets there.
struct RumbleCommandFoldTests {

    @Test func oneSidedCommandReachesBothChannels() {
        let left = RumbleCommand(leftAmp: 900, rightAmp: 0).foldedToMono
        #expect(left.leftAmp == 900 && left.rightAmp == 900)
        let right = RumbleCommand(leftAmp: 0, rightAmp: 400).foldedToMono
        #expect(right.leftAmp == 400 && right.rightAmp == 400)
    }

    @Test func strongerSideWinsWithItsCarrier() {
        let cmd = RumbleCommand(leftAmp: 200, rightAmp: 700,
                                leftFreqOverride: 160, rightFreqOverride: 320).foldedToMono
        #expect(cmd.leftAmp == 700 && cmd.rightAmp == 700)
        #expect(cmd.leftFreqOverride == 320 && cmd.rightFreqOverride == 320)
    }

    @Test func stopStaysStop() {
        #expect(RumbleCommand().foldedToMono.isStop)
    }
}
