import Foundation

public struct ProviderBudgetConfiguration: Codable, Sendable, Equatable {
    public var dailyUSD: Double?
    public var monthlyUSD: Double?

    public init(dailyUSD: Double? = nil, monthlyUSD: Double? = nil) {
        self.dailyUSD = dailyUSD.flatMap { $0 > 0 ? $0 : nil }
        self.monthlyUSD = monthlyUSD.flatMap { $0 > 0 ? $0 : nil }
    }
}

public enum BudgetThreshold: Int, Codable, Sendable { case warning = 80, limit = 100 }

public struct BudgetEvaluation: Sendable, Equatable {
    public let provider: UsageProvider
    public let period: String
    public let limitUSD: Double
    public let spentUSD: Double
    public let threshold: BudgetThreshold
}

public struct BudgetAlertReceipt: Codable, Sendable, Equatable {
    public let key: String
    public let createdAt: Date

    public init(key: String, createdAt: Date) {
        self.key = key
        self.createdAt = createdAt
    }
}

public enum BudgetPolicy {
    public static func evaluations(
        records: [AgentUsageRecord],
        configurations: [UsageProvider: ProviderBudgetConfiguration],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [BudgetEvaluation] {
        configurations.flatMap { provider, configuration in
            let eligible = records.filter { $0.provider == provider && $0.cost.isBudgetEligible }
            return [evaluation(records: eligible, provider: provider, period: "daily", limit: configuration.dailyUSD, components: [.year, .month, .day], calendar: calendar, now: now), evaluation(records: eligible, provider: provider, period: "monthly", limit: configuration.monthlyUSD, components: [.year, .month], calendar: calendar, now: now)].compactMap { $0 }
        }
    }

    private static func evaluation(records: [AgentUsageRecord], provider: UsageProvider, period: String, limit: Double?, components: Set<Calendar.Component>, calendar: Calendar, now: Date) -> BudgetEvaluation? {
        guard let limit, limit > 0 else { return nil }
        let bucket = calendar.dateComponents(components, from: now)
        let spent = records.filter { calendar.dateComponents(components, from: $0.occurredAt) == bucket }.compactMap(\ .cost.usd).reduce(0, +)
        let percent = spent / limit * 100
        let threshold: BudgetThreshold? = percent >= 100 ? .limit : percent >= 80 ? .warning : nil
        return threshold.map { BudgetEvaluation(provider: provider, period: period, limitUSD: limit, spentUSD: spent, threshold: $0) }
    }

    public static func receiptKey(for evaluation: BudgetEvaluation, calendar: Calendar = .current, now: Date = .now) -> String {
        let period = evaluation.period == "daily" ? calendar.dateComponents([.year, .month, .day, .timeZone], from: now) : calendar.dateComponents([.year, .month, .timeZone], from: now)
        return "\(evaluation.provider.rawValue)|\(evaluation.period)|\(period)|\(evaluation.threshold.rawValue)|\(evaluation.limitUSD)"
    }
}
