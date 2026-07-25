namespace PetRunner.Core;

public enum QuotaBarMode
{
    Auto,
    Daily,
    Monthly,
    Plan,
    Off,
}

public enum QuotaBarSegmentKind
{
    BudgetDaily,
    BudgetMonthly,
    QuotaPrimary,
    QuotaSecondary,
    QuotaTertiary,
}

public sealed record QuotaBarSegment(string Label, double UsedPercent, QuotaBarSegmentKind Kind)
{
    public double RemainingPercent => Math.Clamp(100 - UsedPercent, 0, 100);
}

public readonly record struct QuotaBarBudget(double? DailyUSD = null, double? MonthlyUSD = null);

public sealed record QuotaBarResolveInput(
    UsageProvider? Provider,
    bool Visible,
    QuotaBarMode Mode,
    QuotaBarBudget Budget,
    double SpentDailyUSD = 0,
    double SpentMonthlyUSD = 0);

public sealed record QuotaBarResolveResult(
    IReadOnlyList<QuotaBarSegment> Segments,
    QuotaBarBudget? SeededBudget = null)
{
    public static QuotaBarResolveResult Empty { get; } = new([]);
}

/// Resolves under-pet HP bars (Windows: budget path; plan windows require macOS quota fetch).
public static class QuotaBarResolver
{
    public const double DefaultDailyUSD = 10;
    public const double DefaultMonthlyUSD = 100;

    public static QuotaBarResolveResult Resolve(QuotaBarResolveInput input)
    {
        if (!input.Visible || input.Mode == QuotaBarMode.Off || input.Provider is null)
        {
            return QuotaBarResolveResult.Empty;
        }

        return input.Mode switch
        {
            QuotaBarMode.Daily => BudgetResult(daily: true, monthly: false, input, seedIfNeeded: true),
            QuotaBarMode.Monthly => BudgetResult(daily: false, monthly: true, input, seedIfNeeded: true),
            QuotaBarMode.Plan => QuotaBarResolveResult.Empty,
            QuotaBarMode.Auto => Auto(input),
            _ => QuotaBarResolveResult.Empty,
        };
    }

    private static QuotaBarResolveResult Auto(QuotaBarResolveInput input)
    {
        if (input.Budget.DailyUSD is > 0)
        {
            return new([BudgetSegment("Daily", input.SpentDailyUSD, input.Budget.DailyUSD.Value, QuotaBarSegmentKind.BudgetDaily)]);
        }
        if (input.Budget.MonthlyUSD is > 0)
        {
            return new([BudgetSegment("Monthly", input.SpentMonthlyUSD, input.Budget.MonthlyUSD.Value, QuotaBarSegmentKind.BudgetMonthly)]);
        }
        return BudgetResult(daily: true, monthly: true, input, seedIfNeeded: true);
    }

    private static QuotaBarResolveResult BudgetResult(bool daily, bool monthly, QuotaBarResolveInput input, bool seedIfNeeded)
    {
        var budget = input.Budget;
        QuotaBarBudget? seeded = null;
        var needsDaily = daily && !(budget.DailyUSD is > 0);
        var needsMonthly = monthly && !(budget.MonthlyUSD is > 0);
        if (seedIfNeeded && (needsDaily || needsMonthly))
        {
            budget = new QuotaBarBudget(
                needsDaily ? DefaultDailyUSD : budget.DailyUSD,
                needsMonthly ? DefaultMonthlyUSD : budget.MonthlyUSD);
            seeded = budget;
        }

        var segments = new List<QuotaBarSegment>();
        if (daily && budget.DailyUSD is > 0)
        {
            segments.Add(BudgetSegment("Daily", input.SpentDailyUSD, budget.DailyUSD.Value, QuotaBarSegmentKind.BudgetDaily));
        }
        if (monthly && budget.MonthlyUSD is > 0)
        {
            segments.Add(BudgetSegment("Monthly", input.SpentMonthlyUSD, budget.MonthlyUSD.Value, QuotaBarSegmentKind.BudgetMonthly));
        }
        return new(segments, seeded);
    }

    private static QuotaBarSegment BudgetSegment(string label, double spent, double limit, QuotaBarSegmentKind kind)
    {
        var used = limit > 0 ? spent / limit * 100 : 0;
        return new(label, Math.Clamp(used, 0, 100), kind);
    }
}
