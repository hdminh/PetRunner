import Foundation
import PetRunnerCore
import Testing

struct ProviderQuotaParserTests {
    @Test func parsesClaudeSessionAndWeeklyWindows() {
        let snapshot = ProviderQuotaParser.parseClaudeUsage([
            "five_hour": [
                "utilization": 42.5,
                "resets_at": "2026-07-25T18:00:00Z",
            ],
            "seven_day": [
                "utilization": 18,
                "resets_at": "2026-07-31T12:00:00Z",
            ],
            "extra_usage": [
                "is_enabled": true,
                "used_credits": 12.5,
                "monthly_limit": 100,
            ],
        ])

        #expect(snapshot.primary?.usedPercent == 42.5)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary?.usedPercent == 18)
        #expect(snapshot.secondary?.windowMinutes == 10_080)
        #expect(snapshot.monthlySpend?.usedUSD == 12.5)
        #expect(snapshot.monthlySpend?.limitUSD == 100)
        #expect(snapshot.source == "oauth")
    }

    @Test func parsesCodexWhamPrimaryAndSecondaryWindows() {
        let snapshot = ProviderQuotaParser.parseCodexWhamUsage([
            "rate_limit": [
                "primary_window": [
                    "used_percent": 55,
                    "reset_at": 1_753_459_200,
                    "limit_window_seconds": 18_000,
                ],
                "secondary_window": [
                    "used_percent": 12,
                    "reset_at": 1_753_977_600,
                    "limit_window_seconds": 604_800,
                ],
            ],
        ])

        #expect(snapshot.primary?.usedPercent == 55)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary?.usedPercent == 12)
        #expect(snapshot.secondary?.windowMinutes == 10_080)
    }

    @Test func parsesCursorUsageSummaryBillingWindows() {
        let snapshot = ProviderQuotaParser.parseCursorUsageSummary([
            "totalPercentUsed": 67.2,
            "autoPercentUsed": 40,
            "apiPercentUsed": 80,
            "billingCycleStart": "2026-07-01T00:00:00.000Z",
            "billingCycleEnd": "2026-08-01T00:00:00.000Z",
            "onDemand": [
                "used": 1500,
                "limit": 5000,
            ],
        ])

        #expect(snapshot.primary?.usedPercent == 67.2)
        #expect(snapshot.primary?.label == "Included")
        #expect(snapshot.secondary?.usedPercent == 40)
        #expect(snapshot.tertiary?.usedPercent == 80)
        #expect(snapshot.monthlySpend?.usedUSD == 15)
        #expect(snapshot.monthlySpend?.limitUSD == 50)
        #expect(snapshot.source == "localAuth")
        #expect(snapshot.message == nil)
    }

    @Test func parsesCursorUsageSummaryNestedIndividualUsage() {
        let snapshot = ProviderQuotaParser.parseCursorUsageSummary([
            "billingCycleStart": "2026-07-01T00:00:00.000Z",
            "billingCycleEnd": "2026-08-01T00:00:00.000Z",
            "individualUsage": [
                "plan": [
                    "used": 2000,
                    "limit": 2000,
                    "autoPercentUsed": 0,
                    "apiPercentUsed": 100,
                    "totalPercentUsed": 100,
                ],
                "onDemand": [
                    "enabled": true,
                    "used": 2309,
                    "limit": NSNull(),
                ],
            ],
            "teamUsage": [
                "onDemand": [
                    "enabled": true,
                    "used": 5000,
                    "limit": 10_000,
                ],
            ],
        ])

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.primary?.label == "Included")
        #expect(snapshot.primary?.resetsAt != nil)
        #expect(snapshot.secondary?.usedPercent == 0)
        #expect(snapshot.secondary?.label == "Auto")
        #expect(snapshot.tertiary?.usedPercent == 100)
        #expect(snapshot.tertiary?.label == "API")
        // Individual on-demand has no cap → team on-demand used/limit.
        #expect(snapshot.monthlySpend?.usedUSD == 50)
        #expect(snapshot.monthlySpend?.limitUSD == 100)
        #expect(snapshot.source == "localAuth")
        #expect(snapshot.message == nil)
    }

    @Test func parsesCursorUsageSummaryPlanUsedLimitFallback() {
        let snapshot = ProviderQuotaParser.parseCursorUsageSummary([
            "billingCycleEnd": "2026-08-01T00:00:00.000Z",
            "individualUsage": [
                "plan": [
                    "used": 500,
                    "limit": 2000,
                ],
                "onDemand": [
                    "used": 1500,
                    "limit": 5000,
                ],
            ],
        ])

        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.monthlySpend?.usedUSD == 15)
        #expect(snapshot.monthlySpend?.limitUSD == 50)
    }
}
