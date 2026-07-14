using PetRunner.Core;

namespace PetRunner.Tests;

internal static class AnimationTests
{
    public static void Run()
    {
        var playback = new AnimationPlayback(
            idleActions: [new IdleAction([1, 2]), new IdleAction([3, 4])],
            idleDelayProvider: () => 5,
            idleActionIndexProvider: _ => 1);

        playback.Advance(4.99);
        Check.Equal(0, playback.FrameIndex);
        playback.Advance(0.01);
        Check.Equal(3, playback.FrameIndex);
        playback.Advance(AnimationContract.FrameDurations(AnimationState.Idle)[3]);
        Check.Equal(4, playback.FrameIndex);

        playback.Start(AnimationState.Jumping);
        playback.Advance(AnimationContract.FrameDurations(AnimationState.Jumping).Sum() + 0.01);
        Check.Equal(AnimationState.Idle, playback.State);
        Check.Equal(0, playback.FrameIndex);

        Check.Equal(0, LookDirection.FrameIndex(0, 100, 24)!.Value);
        Check.Equal(4, LookDirection.FrameIndex(100, 0, 24)!.Value);
        Check.True(LookDirection.FrameIndex(10, 10, 24) is null, "Deadzone must suppress cursor look");
        Check.Equal(new AtlasAddress(10, 7), LookDirection.Address(15));
    }
}
