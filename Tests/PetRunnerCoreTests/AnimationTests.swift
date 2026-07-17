import CoreGraphics
import Testing
@testable import PetRunnerCore

struct AnimationTests {
    @Test func standardAnimationContract() {
        #expect(AnimationState.idle.row == 0)
        #expect(AnimationState.idle.frameDurations == [0.84, 0.33, 0.33, 0.42, 0.42, 0.96])
        #expect(AnimationState.runningRight.row == 1)
        #expect(AnimationState.runningRight.frameDurations.count == 8)
        #expect(AnimationState.runningLeft.row == 2)
        #expect(AnimationState.waving.row == 3)
        #expect(AnimationState.jumping.row == 4)
        #expect(AnimationState.failed.row == 5)
        #expect(AnimationState.waiting.row == 6)
        #expect(AnimationState.running.row == 7)
        #expect(AnimationState.review.row == 8)
    }

    @Test func jumpingPlaybackRunsThreeCyclesBeforeReturningToIdle() {
        var playback = AnimationPlayback()
        playback.start(.jumping)
        let cycleDuration = AnimationState.jumping.frameDurations.reduce(0, +)
        playback.advance(by: cycleDuration * 3 - 0.001)
        #expect(playback.state == .jumping)
        playback.advance(by: 0.001)
        #expect(playback.state == .idle)
        #expect(playback.frameIndex == 0)
    }

    @Test func autonomousOneShotAnimationsReturnToIdleAtTheirConfiguredCycles() {
        for (state, cycles) in [(AnimationState.waving, 2), (.failed, 1)] {
            var playback = AnimationPlayback()
            playback.start(state)
            let cycleDuration = state.frameDurations.reduce(0, +)
            playback.advance(by: cycleDuration * Double(cycles))
            #expect(playback.state == .idle)
        }
    }

    @Test func idleStartsImmediately() {
        var playback = AnimationPlayback()
        playback.advance(by: AnimationState.idle.frameDurations[0])
        #expect(playback.frameIndex == 1)
    }

    @Test func idleWaitsOneSecondBetweenActions() {
        var playback = AnimationPlayback()
        let actionDuration = AnimationState.idle.frameDurations.reduce(0, +)
        playback.advance(by: actionDuration)
        #expect(playback.state == .idle)
        #expect(playback.frameIndex == 0)
        playback.advance(by: 0.999)
        #expect(playback.frameIndex == 0)
        playback.advance(by: 0.001 + AnimationState.idle.frameDurations[0])
        #expect(playback.frameIndex == 1)
    }

    @Test func idleChoosesAmongConfiguredActions() {
        let actions = [IdleAction(columns: [1, 2]), IdleAction(columns: [3, 4])]
        var playback = AnimationPlayback(
            idleActions: actions,
            idleActionIndexProvider: { _ in 1 }
        )
        #expect(playback.frameIndex == 3)
        playback.advance(by: AnimationState.idle.frameDurations[3])
        #expect(playback.frameIndex == 4)
    }

    @Test func playbackChangesFrameAtExactBoundary() {
        var playback = AnimationPlayback()
        playback.advance(by: AnimationState.idle.frameDurations[0] - 0.001)
        #expect(playback.frameIndex == 0)
        playback.advance(by: 0.001)
        #expect(playback.frameIndex == 1)
        #expect(abs(playback.elapsedInFrame) < 0.000_001)
    }

    @Test func lookDirectionUsesClockwiseScreenCoordinates() {
        #expect(LookDirection.frameIndex(vector: CGVector(dx: 0, dy: 100)) == 0)
        #expect(LookDirection.frameIndex(vector: CGVector(dx: 100, dy: 0)) == 4)
        #expect(LookDirection.frameIndex(vector: CGVector(dx: 0, dy: -100)) == 8)
        #expect(LookDirection.frameIndex(vector: CGVector(dx: -100, dy: 0)) == 12)
        #expect(LookDirection.frameIndex(vector: CGVector(dx: 100, dy: 100)) == 2)
    }

    @Test func lookDirectionDeadzoneAndAtlasAddress() {
        #expect(LookDirection.frameIndex(vector: CGVector(dx: 10, dy: 10), deadzone: 24) == nil)
        #expect(LookDirection.frameIndex(vector: CGVector(dx: 24, dy: 0), deadzone: 24) != nil)
        #expect(LookDirection.atlasAddress(for: 0) == AtlasAddress(row: 9, column: 0))
        #expect(LookDirection.atlasAddress(for: 7) == AtlasAddress(row: 9, column: 7))
        #expect(LookDirection.atlasAddress(for: 8) == AtlasAddress(row: 10, column: 0))
        #expect(LookDirection.atlasAddress(for: 15) == AtlasAddress(row: 10, column: 7))
    }

    @Test func lookDirectionWrapsAcrossUpBoundary() {
        #expect(LookDirection.frameIndex(vector: CGVector(dx: 1, dy: 100)) == 0)
        #expect(LookDirection.frameIndex(vector: CGVector(dx: -1, dy: 100)) == 0)
    }
}
