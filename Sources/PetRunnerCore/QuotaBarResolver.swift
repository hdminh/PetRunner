import Foundation

/// How the under-pet quota HP bar chooses its meters.
public enum QuotaBarMode: String, CaseIterable, Codable, Sendable {
    case auto
    case daily
    case monthly
    case plan
    case off
}

public enum QuotaBarSegmentKind: String, Codable, Sendable {
    case budgetDaily
    case budgetMonthly
    case quotaPrimary
    case quotaSecondary
    case quotaTertiary
}

/// One pixel HP bar under the pet (budget spend or plan quota window).
public struct QuotaBarSegment: Equatable, Sendable, Codable {
    public var label: String
    /// 0…100 percent used (fill depletes as this rises).
    public var usedPercent: Double
    public var kind: QuotaBarSegmentKind

    public init(label: String, usedPercent: Double, kind: QuotaBarSegmentKind) {
        self.label = label
        self.usedPercent = max(0, min(100, usedPercent))
        self.kind = kind
    }

    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

public struct QuotaBarResolveInput: Equatable, Sendable {
    public var provider: UsageProvider?
    public var visible: Bool
    public var mode: QuotaBarMode
    public var budget: ProviderBudgetConfiguration
    public var quota: ProviderQuotaSnapshot?
    public var spentDailyUSD: Double
    public var spentMonthlyUSD: Double

    public init(
        provider: UsageProvider?,
        visible: Bool,
        mode: QuotaBarMode,
        budget: ProviderBudgetConfiguration = .init(),
        quota: ProviderQuotaSnapshot? = nil,
        spentDailyUSD: Double = 0,
        spentMonthlyUSD: Double = 0
    ) {
        self.provider = provider
        self.visible = visible
        self.mode = mode
        self.budget = budget
        self.quota = quota
        self.spentDailyUSD = max(0, spentDailyUSD)
        self.spentMonthlyUSD = max(0, spentMonthlyUSD)
    }
}

public struct QuotaBarResolveResult: Equatable, Sendable {
    public var segments: [QuotaBarSegment]
    /// When auto falls back to enterprise defaults, caller should persist this budget.
    public var seededBudget: ProviderBudgetConfiguration?

    public init(segments: [QuotaBarSegment], seededBudget: ProviderBudgetConfiguration? = nil) {
        self.segments = segments
        self.seededBudget = seededBudget
    }

    public static let empty = QuotaBarResolveResult(segments: [])
}

/// Resolves under-pet HP bars for the Monitor-selected provider.
public enum QuotaBarResolver {
    public static let defaultDailyUSD = 10.0
    public static let defaultMonthlyUSD = 100.0

    public static func resolve(_ input: QuotaBarResolveInput) -> QuotaBarResolveResult {
        guard input.visible, input.mode != .off, input.provider != nil else {
            return .empty
        }

        switch input.mode {
        case .off:
            return .empty
        case .daily:
            return budgetResult(daily: true, monthly: false, input: input, seedIfNeeded: true)
        case .monthly:
            return budgetResult(daily: false, monthly: true, input: input, seedIfNeeded: true)
        case .plan:
            let plan = planSegments(from: input.quota)
            return QuotaBarResolveResult(segments: plan)
        case .auto:
            if let daily = input.budget.dailyUSD, daily > 0 {
                return QuotaBarResolveResult(segments: [
                    budgetSegment(label: "Daily", spent: input.spentDailyUSD, limit: daily, kind: .budgetDaily),
                ])
            }
            if let monthly = input.budget.monthlyUSD, monthly > 0 {
                return QuotaBarResolveResult(segments: [
                    budgetSegment(label: "Monthly", spent: input.spentMonthlyUSD, limit: monthly, kind: .budgetMonthly),
                ])
            }
            let plan = planSegments(from: input.quota)
            if !plan.isEmpty {
                return QuotaBarResolveResult(segments: plan)
            }
            return budgetResult(daily: true, monthly: true, input: input, seedIfNeeded: true)
        }
    }

    private static func budgetResult(
        daily: Bool,
        monthly: Bool,
        input: QuotaBarResolveInput,
        seedIfNeeded: Bool
    ) -> QuotaBarResolveResult {
        var budget = input.budget
        var seeded: ProviderBudgetConfiguration?
        let needsDaily = daily && (budget.dailyUSD == nil || (budget.dailyUSD ?? 0) <= 0)
        let needsMonthly = monthly && (budget.monthlyUSD == nil || (budget.monthlyUSD ?? 0) <= 0)
        if seedIfNeeded, needsDaily || needsMonthly {
            let next = ProviderBudgetConfiguration(
                dailyUSD: needsDaily ? defaultDailyUSD : budget.dailyUSD,
                monthlyUSD: needsMonthly ? defaultMonthlyUSD : budget.monthlyUSD
            )
            budget = next
            seeded = next
        }

        var segments: [QuotaBarSegment] = []
        if daily, let limit = budget.dailyUSD, limit > 0 {
            segments.append(budgetSegment(label: "Daily", spent: input.spentDailyUSD, limit: limit, kind: .budgetDaily))
        }
        if monthly, let limit = budget.monthlyUSD, limit > 0 {
            segments.append(budgetSegment(label: "Monthly", spent: input.spentMonthlyUSD, limit: limit, kind: .budgetMonthly))
        }
        return QuotaBarResolveResult(segments: segments, seededBudget: seeded)
    }

    private static func budgetSegment(label: String, spent: Double, limit: Double, kind: QuotaBarSegmentKind) -> QuotaBarSegment {
        let used = limit > 0 ? (spent / limit) * 100 : 0
        return QuotaBarSegment(label: label, usedPercent: used, kind: kind)
    }

    private static func planSegments(from quota: ProviderQuotaSnapshot?) -> [QuotaBarSegment] {
        guard let quota else { return [] }
        var segments: [QuotaBarSegment] = []
        if let window = quota.primary {
            segments.append(QuotaBarSegment(
                label: window.label ?? "Included",
                usedPercent: window.usedPercent,
                kind: .quotaPrimary
            ))
        }
        if let window = quota.secondary {
            segments.append(QuotaBarSegment(
                label: window.label ?? "Weekly",
                usedPercent: window.usedPercent,
                kind: .quotaSecondary
            ))
        }
        if let window = quota.tertiary {
            segments.append(QuotaBarSegment(
                label: window.label ?? "API",
                usedPercent: window.usedPercent,
                kind: .quotaTertiary
            ))
        }
        return segments
    }
}
