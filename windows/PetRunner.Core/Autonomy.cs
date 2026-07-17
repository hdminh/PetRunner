namespace PetRunner.Core;

public enum AutonomousActionKind { Walk, Wave, Jump, Cry }
public readonly record struct AutonomousAction(AutonomousActionKind Kind, double Duration = 0);

public sealed class AutonomyPolicy(Func<double>? randomUnit = null)
{
    public const double MinimumWait = 10;
    public const double MaximumWait = 20;
    public const double MinimumWalkDuration = 1;
    public const double MaximumWalkDuration = 2;

    private readonly Func<double> randomUnit = randomUnit ?? Random.Shared.NextDouble;
    private double? deadline;
    public bool IsPerforming { get; private set; }

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
            deadline = now + Sample(MinimumWait, MaximumWait);
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
        var choice = Unit();
        if (choice < .40) return new(AutonomousActionKind.Walk, Sample(MinimumWalkDuration, MaximumWalkDuration));
        if (choice < .65) return new(AutonomousActionKind.Wave);
        if (choice < .90) return new(AutonomousActionKind.Jump);
        return new(AutonomousActionKind.Cry);
    }

    public void Finish() => IsPerforming = false;
    public void Cancel() { deadline = null; IsPerforming = false; }

    private double Sample(double lower, double upper) => lower + (upper - lower) * Unit();
    private double Unit() => Math.Clamp(randomUnit(), 0, 1);
}
