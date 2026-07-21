namespace PetRunner.Core;

public enum AutonomousActionKind { Walk, Wave, Jump, Cry }
public readonly record struct AutonomousAction(AutonomousActionKind Kind, double Duration = 0);

public sealed class AutonomyConfiguration
{
    public const double MinimumAllowedWait = 5;
    public const double MaximumAllowedWait = 30;

    public static AutonomyConfiguration Default { get; } = new(10, 20, Enum.GetValues<AutonomousActionKind>());

    public double MinimumWait { get; }
    public double MaximumWait { get; }
    public IReadOnlySet<AutonomousActionKind> EnabledActions { get; }

    private AutonomyConfiguration(double minimumWait, double maximumWait, IEnumerable<AutonomousActionKind> enabledActions)
    {
        MinimumWait = minimumWait;
        MaximumWait = maximumWait;
        EnabledActions = new HashSet<AutonomousActionKind>(enabledActions);
    }

    public static bool TryCreate(
        double minimumWait,
        double maximumWait,
        IEnumerable<AutonomousActionKind> enabledActions,
        out AutonomyConfiguration? configuration)
    {
        var actions = enabledActions.Distinct().ToArray();
        if (double.IsNaN(minimumWait) || double.IsNaN(maximumWait) ||
            double.IsInfinity(minimumWait) || double.IsInfinity(maximumWait) ||
            minimumWait < MinimumAllowedWait || maximumWait > MaximumAllowedWait ||
            minimumWait > maximumWait || actions.Length == 0 || actions.Any(action => !Enum.IsDefined(action)))
        {
            configuration = null;
            return false;
        }

        configuration = new AutonomyConfiguration(minimumWait, maximumWait, actions);
        return true;
    }
}

public sealed class AutonomyPolicy
{
    public const double MinimumWait = 10;
    public const double MaximumWait = 20;
    public const double MinimumWalkDuration = 1;
    public const double MaximumWalkDuration = 2;

    private readonly Func<double> randomUnit;
    private AutonomyConfiguration configuration;
    private double? deadline;
    public bool IsPerforming { get; private set; }

    public AutonomyPolicy(Func<double>? randomUnit = null)
        : this(AutonomyConfiguration.Default, randomUnit) { }

    public AutonomyPolicy(AutonomyConfiguration configuration, Func<double>? randomUnit = null)
    {
        this.configuration = configuration;
        this.randomUnit = randomUnit ?? Random.Shared.NextDouble;
    }

    public void Update(AutonomyConfiguration configuration)
    {
        this.configuration = configuration;
        Cancel();
    }

    public AutonomousAction? Tick(double now, bool isEligible)
    {
        if (!isEligible)
        {
            Cancel();
            return null;
        }
        if (IsPerforming) return null;
        if (deadline is null)
        {
            deadline = now + Sample(configuration.MinimumWait, configuration.MaximumWait);
            return null;
        }
        if (now < deadline) return null;
        deadline = null;
        return StartAction();
    }

    public AutonomousAction? StartAction()
    {
        if (IsPerforming) return null;
        IsPerforming = true;
        var enabled = Enum.GetValues<AutonomousActionKind>().Where(configuration.EnabledActions.Contains).ToArray();
        var totalWeight = enabled.Sum(Weight);
        var threshold = Unit() * totalWeight;
        var kind = enabled[^1];
        foreach (var candidate in enabled)
        {
            threshold -= Weight(candidate);
            if (threshold < 0)
            {
                kind = candidate;
                break;
            }
        }
        return kind == AutonomousActionKind.Walk
            ? new(kind, Sample(MinimumWalkDuration, MaximumWalkDuration))
            : new(kind);
    }

    public void Finish() => IsPerforming = false;
    public void Cancel() { deadline = null; IsPerforming = false; }

    private double Sample(double lower, double upper) => lower + (upper - lower) * Unit();
    private double Unit() => Math.Clamp(randomUnit(), 0, 1);
    private static double Weight(AutonomousActionKind kind) => kind switch
    {
        AutonomousActionKind.Walk => .40,
        AutonomousActionKind.Wave => .25,
        AutonomousActionKind.Jump => .25,
        AutonomousActionKind.Cry => .10,
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };
}
