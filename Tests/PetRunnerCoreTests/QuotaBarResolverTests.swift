import Foundation
import Testing
@testable import PetRunnerCore

struct QuotaBarResolverTests {
    @Test func hiddenOrOffYieldsEmpty() {
        let quota = ProviderQuotaSnapshot(
            primary: RateWindow(usedPercent: 40, label: "Session"),
            source: "oauth"
        )
        #expect(QuotaBarResolver.resolve(.init(
            provider: .claude,
            visible: false,
            mode: .auto,
            quota: quota
        )).segments.isEmpty)
        #expect(QuotaBarResolver.resolve(.init(
            provider: .claude,
            visible: true,
            mode: .off,
            quota: quota
        )).segments.isEmpty)
        #expect(QuotaBarResolver.resolve(.init(
            provider: nil,
            visible: true,
            mode: .auto,
            quota: quota
        )).segments.isEmpty)
    }

    @Test func autoPrefersConfiguredDailyBudget() {
        let result = QuotaBarResolver.resolve(.init(
            provider: .claude,
            visible: true,
            mode: .auto,
            budget: .init(dailyUSD: 20, monthlyUSD: 200),
            quota: ProviderQuotaSnapshot(
                primary: RateWindow(usedPercent: 90, label: "Session"),
                source: "oauth"
            ),
            spentDailyUSD: 5,
            spentMonthlyUSD: 40
        ))
        #expect(result.segments.count == 1)
        #expect(result.segments[0].kind == .budgetDaily)
        #expect(result.segments[0].usedPercent == 25)
        #expect(result.seededBudget == nil)
    }

    @Test func autoUsesPlanQuotaWhenNoDailyBudget() {
        let result = QuotaBarResolver.resolve(.init(
            provider: .claude,
            visible: true,
            mode: .auto,
            budget: .init(),
            quota: ProviderQuotaSnapshot(
                primary: RateWindow(usedPercent: 30, label: "Session"),
                secondary: RateWindow(usedPercent: 55, label: "Weekly"),
                source: "oauth"
            )
        ))
        #expect(result.segments.map(\.kind) == [.quotaPrimary, .quotaSecondary])
        #expect(result.segments.map(\.label) == ["Session", "Weekly"])
        #expect(result.seededBudget == nil)
    }

    @Test func autoSeedsEnterpriseDefaultsWhenNoQuota() {
        let result = QuotaBarResolver.resolve(.init(
            provider: .cursor,
            visible: true,
            mode: .auto,
            budget: .init(),
            quota: .unavailable(source: "localAuth", message: "missing"),
            spentDailyUSD: 2,
            spentMonthlyUSD: 25
        ))
        #expect(result.segments.count == 2)
        #expect(result.segments[0].kind == .budgetDaily)
        #expect(result.segments[0].usedPercent == 20)
        #expect(result.segments[1].kind == .budgetMonthly)
        #expect(result.segments[1].usedPercent == 25)
        #expect(result.seededBudget?.dailyUSD == QuotaBarResolver.defaultDailyUSD)
        #expect(result.seededBudget?.monthlyUSD == QuotaBarResolver.defaultMonthlyUSD)
    }

    @Test func planModeIgnoresBudgets() {
        let result = QuotaBarResolver.resolve(.init(
            provider: .cursor,
            visible: true,
            mode: .plan,
            budget: .init(dailyUSD: 10),
            quota: ProviderQuotaSnapshot(
                primary: RateWindow(usedPercent: 10, label: "Included"),
                secondary: RateWindow(usedPercent: 20, label: "Auto"),
                tertiary: RateWindow(usedPercent: 30, label: "API"),
                source: "localAuth"
            ),
            spentDailyUSD: 9
        ))
        #expect(result.segments.count == 3)
        #expect(result.segments.map(\.kind) == [.quotaPrimary, .quotaSecondary, .quotaTertiary])
    }

    @Test func dailyModeSeedsDefaultWhenUnset() {
        let result = QuotaBarResolver.resolve(.init(
            provider: .codex,
            visible: true,
            mode: .daily,
            budget: .init(),
            spentDailyUSD: 1
        ))
        #expect(result.segments.count == 1)
        #expect(result.segments[0].usedPercent == 10)
        #expect(result.seededBudget?.dailyUSD == 10)
    }
}
