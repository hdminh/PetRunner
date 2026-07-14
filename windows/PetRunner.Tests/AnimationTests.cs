using PetRunner.Core;

namespace PetRunner.Tests;

internal static class AnimationTests
{
    public static void Run()
    {
        var idleDurations = AnimationContract.FrameDurations(AnimationState.Idle);
        Check.Equal(6, idleDurations.Count);
        Check.Equal(0.84, idleDurations[0]);
        Check.Equal(0.96, idleDurations[5]);

        var playback = new AnimationPlayback(
            idleActions: [new IdleAction([1, 2]), new IdleAction([3, 4])],
            idleActionIndexProvider: _ => 1);

        Check.Equal(3, playback.FrameIndex);
        playback.Advance(AnimationContract.FrameDurations(AnimationState.Idle)[3]);
        Check.Equal(4, playback.FrameIndex);

        playback.Start(AnimationState.Jumping);
        var jumpCycle = AnimationContract.FrameDurations(AnimationState.Jumping).Sum();
        playback.Advance(jumpCycle * 3 - 0.01);
        Check.Equal(AnimationState.Jumping, playback.State);
        playback.Advance(0.01);
        Check.Equal(AnimationState.Idle, playback.State);
        Check.Equal(0, playback.FrameIndex);

        playback.Advance(AnimationContract.FrameDurations(AnimationState.Idle)[0]);
        Check.Equal(1, playback.FrameIndex);

        playback = new AnimationPlayback();
        playback.Advance(AnimationContract.FrameDurations(AnimationState.Idle).Sum());
        playback.Advance(0.999);
        Check.Equal(0, playback.FrameIndex);
        playback.Advance(0.001 + AnimationContract.FrameDurations(AnimationState.Idle)[0]);
        Check.Equal(1, playback.FrameIndex);

        Check.Equal(0, LookDirection.FrameIndex(0, 100, 24)!.Value);
        Check.Equal(4, LookDirection.FrameIndex(100, 0, 24)!.Value);
        Check.True(LookDirection.FrameIndex(10, 10, 24) is null, "Deadzone must suppress cursor look");
        Check.Equal(new AtlasAddress(10, 7), LookDirection.Address(15));
    }
}
