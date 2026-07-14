namespace PetRunner.Core;

public enum AnimationState { Idle, RunningRight, RunningLeft, Waving, Jumping, Failed, Waiting, Running, Review }

public static class AnimationContract
{
    public static int Row(AnimationState state) => (int)state;
    public static IReadOnlyList<double> FrameDurations(AnimationState state)
    {
        var count = RustNative.AnimationFrameCount((int)state);
        RustNative.Require(count < 0 ? 1 : 0);
        return Enumerable.Range(0, count).Select(index => RustNative.AnimationFrameDuration((int)state, index)).ToArray();
    }
    public static int? CyclesBeforeReturningToIdle(AnimationState state) =>
        RustNative.AnimationCyclesBeforeIdle((int)state) is var cycles && cycles > 0 ? cycles : null;
}

public sealed record IdleAction(IReadOnlyList<int> Columns) { public static IdleAction Standard { get; } = new([0, 1, 2, 3, 4, 5]); }

public sealed class AnimationPlayback : IDisposable
{
    private IntPtr handle;

    public AnimationPlayback(AnimationState state = AnimationState.Idle, IReadOnlyList<IdleAction>? idleActions = null, Func<int, int>? idleActionIndexProvider = null)
    {
        RustNative.Require(RustNative.AnimationCreate((int)state, out handle));
    }

    public AnimationState State => (AnimationState)Snapshot.State;
    public int FrameIndex => Snapshot.FrameIndex;
    public double ElapsedInFrame => Snapshot.ElapsedInFrame;
    public AtlasAddress Address => new(Snapshot.Row, Snapshot.Column);

    private RustAnimationSnapshot Snapshot { get { RustNative.Require(RustNative.AnimationSnapshot(handle, out var snapshot)); return snapshot; } }
    public void Start(AnimationState state) => RustNative.Require(RustNative.AnimationStart(handle, (int)state));
    public void Advance(double deltaTime) => RustNative.Require(RustNative.AnimationAdvance(handle, deltaTime));

    public void Dispose()
    {
        if (handle == IntPtr.Zero) return;
        RustNative.AnimationDestroy(handle);
        handle = IntPtr.Zero;
        GC.SuppressFinalize(this);
    }
    ~AnimationPlayback() => Dispose();
}

public static class LookDirection
{
    public static int? FrameIndex(double dx, double dyUp, double deadzone = 24)
    {
        if (!RustNative.LookDirection(dx, dyUp, deadzone, out var address)) return null;
        return address.Row == 9 ? address.Column : address.Column + 8;
    }
    public static AtlasAddress Address(int frameIndex) => frameIndex switch
    {
        >= 0 and < 8 => new(9, frameIndex),
        >= 8 and < 16 => new(10, frameIndex - 8),
        _ => throw new ArgumentOutOfRangeException(nameof(frameIndex)),
    };
}
