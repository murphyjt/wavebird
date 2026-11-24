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

// The idle sweep disconnects a controller whose signature stops changing.
// A stick jittering around neutral must not count as input.
struct IdleSignatureTests {

    private func state(lx: Int16) -> ControllerState {
        var s = ControllerState.zero
        s.leftStick = SIMD2(lx, 0)
        return s
    }

    @Test func jitterAroundNeutralKeepsOneSignature() {
        let sigs = Set([-127, -2, -1, 0, 1, 2, 127].map { state(lx: Int16($0)).idleSignature })
        #expect(sigs.count == 1)
    }

    @Test func realDeflectionChangesSignature() {
        #expect(state(lx: 0).idleSignature != state(lx: 300).idleSignature)
        #expect(state(lx: 0).idleSignature != state(lx: -300).idleSignature)
    }

    @Test func railsStayInRange() {
        #expect(ControllerState.idleBucket(2047) == 8)
        #expect(ControllerState.idleBucket(-2047) == -8)
    }
}
