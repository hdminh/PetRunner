namespace PetRunner.Core;

public enum AnimationState
{
    Idle,
    RunningRight,
    RunningLeft,
    Waving,
    Jumping,
    Failed,
    Waiting,
    Running,
    Review,
}

public static class AnimationContract
{
    private static readonly IReadOnlyDictionary<AnimationState, double[]> Durations =
        new Dictionary<AnimationState, double[]>
        {
            [AnimationState.Idle] = [0.28, 0.11, 0.11, 0.14, 0.14, 0.32],
            [AnimationState.RunningRight] = Frames(8, 0.12, 0.22),
            [AnimationState.RunningLeft] = Frames(8, 0.12, 0.22),
            [AnimationState.Waving] = Frames(4, 0.14, 0.28),
            [AnimationState.Jumping] = Frames(5, 0.14, 0.28),
            [AnimationState.Failed] = Frames(8, 0.14, 0.24),
            [AnimationState.Waiting] = Frames(6, 0.15, 0.26),
            [AnimationState.Running] = Frames(6, 0.12, 0.22),
            [AnimationState.Review] = Frames(6, 0.15, 0.28),
        };

    public static int Row(AnimationState state) => (int)state;
    public static IReadOnlyList<double> FrameDurations(AnimationState state) => Durations[state];
    public static bool IsOneShot(AnimationState state) => state == AnimationState.Jumping;

    private static double[] Frames(int count, double regular, double last) =>
        Enumerable.Range(0, count).Select(index => index == count - 1 ? last : regular).ToArray();
}

public sealed record IdleAction(IReadOnlyList<int> Columns)
{
    public static IdleAction Standard { get; } = new([0, 1, 2, 3, 4, 5]);
}

public sealed class AnimationPlayback
{
    private readonly IReadOnlyList<IdleAction> idleActions;
    private readonly Func<double> idleDelayProvider;
    private readonly Func<int, int> idleActionIndexProvider;
    private IReadOnlyList<int> idleColumns = [];
    private int idlePosition;
    private double idleWaitRemaining;

    public AnimationPlayback(
        AnimationState state = AnimationState.Idle,
        IReadOnlyList<IdleAction>? idleActions = null,
        Func<double>? idleDelayProvider = null,
        Func<int, int>? idleActionIndexProvider = null)
    {
        State = state;
        this.idleActions = Normalize(idleActions);
        this.idleDelayProvider = idleDelayProvider ?? (() => 5 + Random.Shared.NextDouble() * 5);
        this.idleActionIndexProvider = idleActionIndexProvider ?? Random.Shared.Next;
        if (state == AnimationState.Idle) ScheduleIdle();
    }

    public AnimationState State { get; private set; }
    public int FrameIndex { get; private set; }
    public double ElapsedInFrame { get; private set; }
    public bool IsIdleActionPlaying { get; private set; }
    public AtlasAddress Address => new(AnimationContract.Row(State), FrameIndex);

    public void Start(AnimationState state)
    {
        State = state;
        FrameIndex = 0;
        ElapsedInFrame = 0;
        IsIdleActionPlaying = false;
        if (state == AnimationState.Idle) ScheduleIdle();
    }

    public void Advance(double deltaTime)
    {
        if (deltaTime <= 0) return;
        if (State == AnimationState.Idle)
        {
            AdvanceIdle(deltaTime);
            return;
        }

        ElapsedInFrame += deltaTime;
        var durations = AnimationContract.FrameDurations(State);
        while (ElapsedInFrame + 1e-12 >= durations[FrameIndex])
        {
            ElapsedInFrame -= durations[FrameIndex];
            FrameIndex++;
            if (FrameIndex != durations.Count) continue;
            if (AnimationContract.IsOneShot(State))
            {
                Start(AnimationState.Idle);
                return;
            }
            FrameIndex = 0;
        }
    }

    private void AdvanceIdle(double deltaTime)
    {
        var remaining = deltaTime;
        while (remaining > 1e-12)
        {
            if (!IsIdleActionPlaying)
            {
                if (remaining + 1e-12 < idleWaitRemaining)
                {
                    idleWaitRemaining -= remaining;
                    return;
                }
                remaining = Math.Max(0, remaining - idleWaitRemaining);
                BeginIdleAction();
                continue;
            }

            var duration = AnimationContract.FrameDurations(AnimationState.Idle)[FrameIndex];
            var toBoundary = duration - ElapsedInFrame;
            if (remaining + 1e-12 < toBoundary)
            {
                ElapsedInFrame += remaining;
                return;
            }
            remaining = Math.Max(0, remaining - toBoundary);
            ElapsedInFrame = 0;
            idlePosition++;
            if (idlePosition == idleColumns.Count)
            {
                FrameIndex = 0;
                IsIdleActionPlaying = false;
                ScheduleIdle();
            }
            else
            {
                FrameIndex = idleColumns[idlePosition];
            }
        }
    }

    private void BeginIdleAction()
    {
        var requested = idleActionIndexProvider(idleActions.Count);
        var index = ((requested % idleActions.Count) + idleActions.Count) % idleActions.Count;
        idleColumns = idleActions[index].Columns;
        idlePosition = 0;
        FrameIndex = idleColumns[0];
        ElapsedInFrame = 0;
        IsIdleActionPlaying = true;
        idleWaitRemaining = 0;
    }

    private void ScheduleIdle()
    {
        var requested = idleDelayProvider();
        idleWaitRemaining = double.IsFinite(requested) ? Math.Clamp(requested, 5, 10) : 5;
    }

    private static IReadOnlyList<IdleAction> Normalize(IReadOnlyList<IdleAction>? actions)
    {
        if (actions is null || actions.Count == 0) return [IdleAction.Standard];
        return actions.Select(action =>
        {
            var columns = action.Columns.Where(column => column is >= 0 and < 6).ToArray();
            return new IdleAction(columns.Length == 0 ? [0] : columns);
        }).ToArray();
    }
}

public static class LookDirection
{
    public static int? FrameIndex(double dx, double dyUp, double deadzone = 24)
    {
        if (Math.Hypot(dx, dyUp) < deadzone) return null;
        var angle = Math.Atan2(dx, dyUp);
        if (angle < 0) angle += 2 * Math.PI;
        return (int)Math.Round(angle / (Math.PI / 8), MidpointRounding.AwayFromZero) % 16;
    }

    public static AtlasAddress Address(int frameIndex)
    {
        if (frameIndex is < 0 or >= 16) throw new ArgumentOutOfRangeException(nameof(frameIndex));
        return frameIndex < 8 ? new AtlasAddress(9, frameIndex) : new AtlasAddress(10, frameIndex - 8);
    }
}
