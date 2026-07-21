using PetRunner.Core;

namespace PetRunner.Tests;

internal static class AutonomyTests
{
    public static void Run()
    {
        ConfigurationValidatesBoundsAndFiltersActions();
        SchedulesWithinApprovedBounds();
        SelectsConfiguredActionsFromWeights();
        ImmediatelyStartsAnActionUsingTheConfiguredWeights();
        CancellationDiscardsPendingWait();
        UpdatingConfigurationCancelsAnExistingWait();
    }

    private static void ConfigurationValidatesBoundsAndFiltersActions()
    {
        Check.True(!AutonomyConfiguration.TryCreate(4, 20, [AutonomousActionKind.Walk], out _),
            "Waits below five seconds must be rejected");
        Check.True(!AutonomyConfiguration.TryCreate(10, 31, [AutonomousActionKind.Walk], out _),
            "Waits above thirty seconds must be rejected");
        Check.True(!AutonomyConfiguration.TryCreate(20, 10, [AutonomousActionKind.Walk], out _),
            "The minimum wait cannot exceed the maximum");
        Check.True(!AutonomyConfiguration.TryCreate(10, 20, [], out _),
            "At least one autonomous action must be enabled");

        Check.True(AutonomyConfiguration.TryCreate(10, 10, [AutonomousActionKind.Cry], out var configuration),
            "A bounded single-action configuration should be valid");
        var units = new Queue<double>(new[] { 0d, 0d });
        var policy = new AutonomyPolicy(configuration, () => units.Dequeue());
        Check.True(policy.Tick(0, true) is null, "First eligible tick should schedule autonomy");
        Check.Equal(AutonomousActionKind.Cry, policy.Tick(10, true)!.Value.Kind);
    }

    private static void SchedulesWithinApprovedBounds()
    {
        var policy = new AutonomyPolicy(() => 0);
        Check.True(policy.Tick(100, true) is null, "First eligible tick should schedule autonomy");
        Check.True(policy.Tick(109.999, true) is null, "Action must not start before the deadline");
        var action = policy.Tick(110, true);
        Check.Equal(AutonomousActionKind.Walk, action!.Value.Kind);
        Check.Equal(1d, action.Value.Duration);

        var maximumPolicy = new AutonomyPolicy(() => 1);
        Check.True(maximumPolicy.Tick(200, true) is null, "First eligible tick should schedule autonomy");
        Check.True(maximumPolicy.Tick(219.999, true) is null, "Action must not start before the deadline");
        Check.Equal(AutonomousActionKind.Cry, maximumPolicy.Tick(220, true)!.Value.Kind);
    }

    private static void SelectsConfiguredActionsFromWeights()
    {
        var cases = new (double Choice, AutonomousActionKind Expected)[]
        {
            (.39, AutonomousActionKind.Walk),
            (.40, AutonomousActionKind.Wave),
            (.65, AutonomousActionKind.Jump),
            (.90, AutonomousActionKind.Cry),
        };

        foreach (var item in cases)
        {
            var units = new Queue<double>(new[] { 0d, item.Choice, 0d });
            var policy = new AutonomyPolicy(() => units.Dequeue());
            Check.True(policy.Tick(0, true) is null, "Eligible tick should schedule first");
            Check.Equal(item.Expected, policy.Tick(10, true)!.Value.Kind);
        }
    }

    private static void ImmediatelyStartsAnActionUsingTheConfiguredWeights()
    {
        var policy = new AutonomyPolicy(() => 0.65);
        var action = policy.StartAction();

        Check.Equal(AutonomousActionKind.Jump, action!.Value.Kind);
        Check.True(policy.IsPerforming, "Starting an action immediately should mark the policy as performing");
    }

    private static void CancellationDiscardsPendingWait()
    {
        var policy = new AutonomyPolicy(() => 0);
        policy.Tick(0, true);
        policy.Cancel();
        Check.True(policy.Tick(10, true) is null, "Cancel must discard the original deadline");
        Check.True(policy.Tick(20, true) is { } action && action.Kind == AutonomousActionKind.Walk,
            "A fresh wait should be scheduled after cancellation");

        Check.True(policy.Tick(30, false) is null, "Ineligible ticks must not schedule work");
        Check.True(policy.Tick(30, true) is null, "Pet should start a fresh wait after becoming eligible");
        Check.True(policy.Tick(40, true) is { } rescheduledAction && rescheduledAction.Kind == AutonomousActionKind.Walk,
            "Ineligible ticks must discard the pending deadline");
    }

    private static void UpdatingConfigurationCancelsAnExistingWait()
    {
        var policy = new AutonomyPolicy(() => 0);
        policy.Tick(0, true);
        Check.True(AutonomyConfiguration.TryCreate(10, 10, [AutonomousActionKind.Wave], out var configuration),
            "The wave-only configuration should be valid");
        policy.Update(configuration!);
        Check.True(policy.Tick(10, true) is null, "Updating configuration must discard the existing wait");
        Check.Equal(AutonomousActionKind.Wave, policy.Tick(20, true)!.Value.Kind);
    }
}
