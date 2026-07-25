import CryptoKit
import Foundation
import SQLite3

public enum UsageProvider: String, CaseIterable, Codable, Sendable {
    case claude, codex, cursor

    public var displayName: String { rawValue.capitalized }
}

public enum UsageCostProvenance: String, Codable, Sendable {
    case providerReported
    case calculated
    case estimated
    case unavailable
}

public struct UsageTokenBreakdown: Codable, Equatable, Sendable {
    /// Non-cached input tokens. For Codex this is the provider-reported total
    /// input and `cachedInput` is a subset; the pricing catalog accounts for
    /// that relationship when calculating cost.
    public var input: Int
    public var cachedInput: Int
    /// Tokens used to create a prompt cache. Claude bills these separately
    /// from normal input, so they must not be folded into `input`.
    public var cacheCreation: Int
    /// The one-hour subset of `cacheCreation`, when Claude provides it.
    public var cacheCreation1h: Int
    public var output: Int
    /// Informational only: Codex reports reasoning as part of output, so it
    /// is deliberately excluded from `total` and calculated cost.
    public var reasoning: Int

    public init(input: Int = 0, cachedInput: Int = 0, cacheCreation: Int = 0, cacheCreation1h: Int = 0, output: Int = 0, reasoning: Int = 0) {
        self.input = max(0, input)
        self.cachedInput = max(0, cachedInput)
        self.cacheCreation = max(0, cacheCreation)
        self.cacheCreation1h = min(max(0, cacheCreation1h), self.cacheCreation)
        self.output = max(0, output)
        self.reasoning = max(0, reasoning)
    }

    public var total: Int { input + cachedInput + cacheCreation + output }

    private enum CodingKeys: String, CodingKey {
        case input, cachedInput, cacheCreation, cacheCreation1h, output, reasoning
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            input: try container.decodeIfPresent(Int.self, forKey: .input) ?? 0,
            cachedInput: try container.decodeIfPresent(Int.self, forKey: .cachedInput) ?? 0,
            cacheCreation: try container.decodeIfPresent(Int.self, forKey: .cacheCreation) ?? 0,
            cacheCreation1h: try container.decodeIfPresent(Int.self, forKey: .cacheCreation1h) ?? 0,
            output: try container.decodeIfPresent(Int.self, forKey: .output) ?? 0,
            reasoning: try container.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0)
    }
}

public struct UsageCost: Codable, Equatable, Sendable {
    public let usd: Double?
    public let provenance: UsageCostProvenance
    public let pricingVersion: String?
    public let isBudgetEligible: Bool

    public init(usd: Double?, provenance: UsageCostProvenance, pricingVersion: String? = nil, isBudgetEligible: Bool? = nil) {
        self.usd = usd.map { max(0, $0) }
        self.provenance = provenance
        self.pricingVersion = pricingVersion
        self.isBudgetEligible = isBudgetEligible ?? (provenance == .providerReported || provenance == .calculated)
    }
}

/// Cursor plan vs overage billing category. Local Claude/Codex rows leave this nil.
public enum UsageBillingType: String, Codable, Sendable {
    case included
    case onDemand
}

public struct AgentUsageRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: UsageProvider
    public let sessionID: String
    public let occurredAt: Date
    public let model: String?
    public let tokens: UsageTokenBreakdown
    public let cost: UsageCost
    /// Cursor included-plan vs on-demand overage; nil for local Claude/Codex rows.
    public let usageType: UsageBillingType?
    /// Codex reports cached input as a subset of input; Claude and Cursor
    /// report cache categories independently.
    public var totalTokens: Int {
        provider == .codex ? tokens.input + tokens.cacheCreation + tokens.output : tokens.total
    }

    public init(id: String, provider: UsageProvider, sessionID: String, occurredAt: Date, model: String?, tokens: UsageTokenBreakdown, cost: UsageCost, usageType: UsageBillingType? = nil) {
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.occurredAt = occurredAt
        self.model = model
        self.tokens = tokens
        self.cost = cost
        self.usageType = usageType
    }
}

/// Safe, provider-neutral metadata for a historical local session. It never
/// contains a prompt, response, or tool output. `projectPath` may retain the
/// local cwd for Analytics project cards (same machine as the JSONL sources).
public struct HistoricalUsageSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue):\(sessionID)" }
    public let provider: UsageProvider
    public let sessionID: String
    public let projectName: String?
    /// Absolute or relative cwd when known (Claude/Codex JSONL, or Cursor local IDE state).
    public let projectPath: String?
    public let title: String?
    public let startedAt: Date
    public let lastActivityAt: Date
    public let model: String?
    public let sourceRevision: String

    public init(provider: UsageProvider, sessionID: String, projectName: String?, title: String?, startedAt: Date, lastActivityAt: Date, model: String?, sourceRevision: String = LocalUsageSource.historicalParserRevision, projectPath: String? = nil) {
        self.provider = provider
        self.sessionID = sessionID
        self.projectPath = sanitizedProjectPath(projectPath)
        self.projectName = sanitizedProjectName(projectName) ?? sanitizedProjectName(projectPath)
        self.title = sanitizedSessionTitle(title)
        self.startedAt = min(startedAt, lastActivityAt)
        self.lastActivityAt = max(startedAt, lastActivityAt)
        self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sourceRevision = sourceRevision
    }
}

public struct HistoricalUsageSourceReceipt: Codable, Equatable, Sendable, Identifiable {
    /// Local scanner identity only; never return this in dashboard payloads.
    public let sourceKey: String
    public let fileSize: Int64
    public let modifiedAt: Date
    public let parserRevision: String

    public var id: String { sourceKey }

    public init(sourceKey: String, fileSize: Int64, modifiedAt: Date, parserRevision: String) {
        self.sourceKey = sourceKey
        self.fileSize = max(0, fileSize)
        self.modifiedAt = modifiedAt
        self.parserRevision = parserRevision
    }
}

public struct HistoricalUsageScan: Sendable, Equatable {
    public let records: [AgentUsageRecord]
    public let sessions: [HistoricalUsageSession]
    public let sourceReceipts: [HistoricalUsageSourceReceipt]

    public init(records: [AgentUsageRecord] = [], sessions: [HistoricalUsageSession] = [], sourceReceipts: [HistoricalUsageSourceReceipt] = []) {
        self.records = records
        self.sessions = sessions
        self.sourceReceipts = sourceReceipts
    }
}

public struct HistoricalUsageSessionQuery: Sendable {
    public var providers: Set<UsageProvider>?
    public var startDate: Date?
    public var endDate: Date?
    public var sessionID: String?

    public init(providers: Set<UsageProvider>? = nil, startDate: Date? = nil, endDate: Date? = nil, sessionID: String? = nil) {
        self.providers = providers
        self.startDate = startDate
        self.endDate = endDate
        self.sessionID = sessionID
    }
}

public struct UsageQuery: Sendable {
    public var providers: Set<UsageProvider>?
    public var startDate: Date?
    public var endDate: Date?
    public var sessionID: String?

    public init(providers: Set<UsageProvider>? = nil, startDate: Date? = nil, endDate: Date? = nil, sessionID: String? = nil) {
        self.providers = providers
        self.startDate = startDate
        self.endDate = endDate
        self.sessionID = sessionID
    }
}

public struct UsageAggregate: Sendable {
    public let records: [AgentUsageRecord]
    public let tokens: UsageTokenBreakdown
    public let totalTokens: Int
    public let knownCostUSD: Double
    public let sessionCount: Int

    public init(records: [AgentUsageRecord]) {
        self.records = records
        tokens = records.reduce(into: UsageTokenBreakdown()) { result, record in
            result.input += record.tokens.input; result.cachedInput += record.tokens.cachedInput
            result.cacheCreation += record.tokens.cacheCreation
            result.cacheCreation1h += record.tokens.cacheCreation1h
            result.output += record.tokens.output; result.reasoning += record.tokens.reasoning
        }
        totalTokens = records.reduce(0) { $0 + $1.totalTokens }
        knownCostUSD = records.compactMap(\ .cost.usd).reduce(0, +)
        sessionCount = Set(records.map { "\($0.provider.rawValue):\($0.sessionID)" }).count
    }
}

/// Session row built from usage ledger records (ccgauge `aggregateBySession`):
/// one row per provider + sessionID, cost = sum of known record costs.
public struct UsageSessionSummary: Equatable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue):\(sessionID)" }
    public let provider: UsageProvider
    public let sessionID: String
    public let title: String
    public let project: String?
    public let projectPath: String?
    public let startedAt: Date
    public let lastActivityAt: Date
    public let models: [String]
    public let primaryModel: String?
    public let requestCount: Int
    public let tokens: UsageTokenBreakdown
    public let totalTokens: Int
    public let knownCostUSD: Double?
    public let unpricedRecordCount: Int
    public let provenance: String

    public var durationSeconds: TimeInterval {
        max(0, lastActivityAt.timeIntervalSince(startedAt))
    }
}

/// Project rollup (ccgauge `aggregateByProject`): group by project path/name.
public struct UsageProjectSummary: Equatable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue):\(projectKey)" }
    public let provider: UsageProvider
    public let projectKey: String
    public let name: String
    public let path: String?
    public let sessionCount: Int
    public let requestCount: Int
    public let tokens: UsageTokenBreakdown
    public let totalTokens: Int
    public let knownCostUSD: Double
    public let lastActivityAt: Date
    public let models: [String]
}

/// Model rollup (ccgauge `aggregateByModel`) with share + cache-savings fields.
public struct UsageModelSummary: Equatable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue):\(model)" }
    public let provider: UsageProvider
    public let model: String
    public let displayName: String
    public let requestCount: Int
    public let tokens: UsageTokenBreakdown
    public let totalTokens: Int
    public let knownCostUSD: Double
    public let cacheSavedUSD: Double
    public let costShare: Double
    public let tokenShare: Double
    public let cacheHitRatio: Double
    public let pricingResolved: Bool
    public let inputPerMillionUSD: Double?
    public let outputPerMillionUSD: Double?
    public let cacheReadPerMillionUSD: Double?
}

/// Groups usage records by provider + sessionID and attributes cost like
/// ccgauge's `aggregateBySession`: sum each record's known cost.
public enum UsageSessionAggregator {
    public static func sessions(
        from records: [AgentUsageRecord],
        metadata: [HistoricalUsageSession] = []
    ) -> [UsageSessionSummary] {
        let metaByKey = Dictionary(uniqueKeysWithValues: metadata.map {
            ("\($0.provider.rawValue):\($0.sessionID)", $0)
        })
        let grouped = Dictionary(grouping: records) {
            "\($0.provider.rawValue):\($0.sessionID)"
        }
        return grouped.values.compactMap { group -> UsageSessionSummary? in
            guard let first = group.first else { return nil }
            let ordered = group.sorted { $0.occurredAt < $1.occurredAt }
            let startedAt = ordered.first?.occurredAt ?? first.occurredAt
            let lastActivityAt = ordered.last?.occurredAt ?? first.occurredAt
            let aggregate = UsageAggregate(records: group)
            let modelTotals = Dictionary(grouping: group.compactMap { record -> (String, Int)? in
                record.model.map { ($0, record.totalTokens) }
            }, by: \.0).mapValues { values in values.reduce(0) { $0 + $1.1 } }
            let models = modelTotals.keys.sorted { left, right in
                let leftTokens = modelTotals[left, default: 0]
                let rightTokens = modelTotals[right, default: 0]
                return leftTokens == rightTokens ? left < right : leftTokens > rightTokens
            }
            let knownCosts = group.compactMap(\.cost.usd)
            let provenances = Set(group.map(\.cost.provenance.rawValue))
            let key = "\(first.provider.rawValue):\(first.sessionID)"
            let meta = metaByKey[key]
            let title = meta?.title?.nilIfEmpty
                ?? models.first
                ?? shortSessionTitle(first.sessionID)
            return UsageSessionSummary(
                provider: first.provider,
                sessionID: first.sessionID,
                title: title,
                project: meta?.projectName,
                projectPath: meta?.projectPath,
                startedAt: startedAt,
                lastActivityAt: lastActivityAt,
                models: models,
                primaryModel: models.first ?? meta?.model,
                requestCount: group.count,
                tokens: aggregate.tokens,
                totalTokens: aggregate.totalTokens,
                knownCostUSD: knownCosts.isEmpty ? nil : knownCosts.reduce(0, +),
                unpricedRecordCount: group.count - knownCosts.count,
                provenance: provenances.isEmpty
                    ? "unavailable"
                    : provenances.count == 1 ? (provenances.first ?? "unavailable") : "mixed"
            )
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    public static func projects(
        from records: [AgentUsageRecord],
        metadata: [HistoricalUsageSession] = []
    ) -> [UsageProjectSummary] {
        let sessions = Self.sessions(from: records, metadata: metadata)
        let grouped = Dictionary(grouping: sessions) { session -> String in
            let key = session.projectPath?.nilIfEmpty
                ?? session.project?.nilIfEmpty
                ?? "(unknown)"
            return "\(session.provider.rawValue)::\(key)"
        }
        return grouped.values.compactMap { group -> UsageProjectSummary? in
            guard let first = group.first else { return nil }
            let path = first.projectPath
            let name = first.project
                ?? sanitizedProjectName(path)
                ?? "(unknown)"
            let projectKey = path ?? name
            let requestCount = group.reduce(0) { $0 + $1.requestCount }
            let tokens = group.reduce(into: UsageTokenBreakdown()) { result, session in
                result.input += session.tokens.input
                result.cachedInput += session.tokens.cachedInput
                result.cacheCreation += session.tokens.cacheCreation
                result.cacheCreation1h += session.tokens.cacheCreation1h
                result.output += session.tokens.output
                result.reasoning += session.tokens.reasoning
            }
            let totalTokens = group.reduce(0) { $0 + $1.totalTokens }
            let cost = group.compactMap(\.knownCostUSD).reduce(0, +)
            let lastActivity = group.map(\.lastActivityAt).max() ?? first.lastActivityAt
            var models: [String] = []
            var seen = Set<String>()
            for session in group.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }) {
                for model in session.models where seen.insert(model).inserted {
                    models.append(model)
                }
            }
            return UsageProjectSummary(
                provider: first.provider,
                projectKey: projectKey,
                name: name,
                path: path,
                sessionCount: group.count,
                requestCount: requestCount,
                tokens: tokens,
                totalTokens: totalTokens,
                knownCostUSD: cost,
                lastActivityAt: lastActivity,
                models: models
            )
        }
        .sorted { $0.knownCostUSD > $1.knownCostUSD }
    }

    public static func models(
        from records: [AgentUsageRecord]
    ) -> [UsageModelSummary] {
        let grouped = Dictionary(grouping: records.filter { ($0.model ?? "").isEmpty == false }) {
            "\($0.provider.rawValue):\($0.model ?? "")"
        }
        let totalsByProvider = Dictionary(grouping: records, by: \.provider).mapValues { group in
            (
                cost: group.compactMap(\.cost.usd).reduce(0, +),
                tokens: group.reduce(0) { $0 + $1.totalTokens }
            )
        }
        return grouped.values.compactMap { group -> UsageModelSummary? in
            guard let first = group.first, let model = first.model?.nilIfEmpty else { return nil }
            let aggregate = UsageAggregate(records: group)
            let knownCost = group.compactMap(\.cost.usd).reduce(0, +)
            let pricing = BundledPricing.resolved(model: model)
            let cacheSaved = group.reduce(0.0) { partial, record in
                partial + BundledPricing.cacheSavingsUSD(model: record.model, tokens: record.tokens)
            }
            let providerTotals = totalsByProvider[first.provider] ?? (cost: 0, tokens: 0)
            let inputDenom = max(1, aggregate.tokens.cachedInput + aggregate.tokens.input + aggregate.tokens.cacheCreation)
            let cacheHit = Double(aggregate.tokens.cachedInput) / Double(inputDenom)
            return UsageModelSummary(
                provider: first.provider,
                model: model,
                displayName: BundledPricing.shortDisplayName(model),
                requestCount: group.count,
                tokens: aggregate.tokens,
                totalTokens: aggregate.totalTokens,
                knownCostUSD: knownCost,
                cacheSavedUSD: cacheSaved,
                costShare: providerTotals.cost > 0 ? knownCost / providerTotals.cost : 0,
                tokenShare: providerTotals.tokens > 0 ? Double(aggregate.totalTokens) / Double(providerTotals.tokens) : 0,
                cacheHitRatio: cacheHit,
                pricingResolved: pricing != nil,
                inputPerMillionUSD: pricing.map { $0.input * 1_000_000 },
                outputPerMillionUSD: pricing.map { $0.output * 1_000_000 },
                cacheReadPerMillionUSD: pricing.flatMap { rates in
                    rates.cachedInput.map { $0 * 1_000_000 }
                }
            )
        }
        .sorted { $0.knownCostUSD > $1.knownCostUSD }
    }

    private static func shortSessionTitle(_ sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled session" }
        let stripped = trimmed
            .replacingOccurrences(of: #"^(conv|gap):"#, with: "", options: .regularExpression)
        if stripped.count <= 12 { return stripped }
        return String(stripped.prefix(8)) + "…"
    }
}

/// Cursor session identity when the usage API lacks Claude/Codex-style session files.
///
/// Heuristic (documented for Analytics):
/// 1. Prefer a real conversation id from the event (`conversationId` / `chatId` /
///    `composerId`) → `sessionID = "conv:<id>"`.
/// 2. Otherwise chronologically cluster events: a gap larger than `sessionGap`
///    starts a new session → `sessionID = "gap:<startMs>"`.
/// 3. Project path/name come from local Cursor IDE state (`CursorLocalSessionIndex`)
///    keyed by conversation id. Unattributed sessions stay pathless (`(unknown)`),
///    not a single synthetic `"Cursor"` project.
public enum CursorSessionGrouping {
    public static let sessionGap: TimeInterval = 30 * 60

    public static func assignSessionIDs(
        _ records: [AgentUsageRecord],
        conversationIDs: [String: String] = [:],
        gap: TimeInterval = sessionGap
    ) -> [AgentUsageRecord] {
        guard !records.isEmpty else { return [] }
        let ordered = records.sorted { $0.occurredAt < $1.occurredAt }
        var assigned: [AgentUsageRecord] = []
        var currentGapSession: String?
        var previousUngroupedAt: Date?

        for record in ordered {
            let conversation = conversationIDs[record.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let sessionID: String
            if let conversation {
                sessionID = conversation.hasPrefix("conv:") ? conversation : "conv:\(conversation)"
                currentGapSession = nil
                previousUngroupedAt = nil
            } else if let previous = previousUngroupedAt,
                      let openSession = currentGapSession,
                      record.occurredAt.timeIntervalSince(previous) <= gap {
                sessionID = openSession
                previousUngroupedAt = record.occurredAt
            } else {
                let startMs = Int64(record.occurredAt.timeIntervalSince1970 * 1_000)
                sessionID = "gap:\(startMs)"
                currentGapSession = sessionID
                previousUngroupedAt = record.occurredAt
            }
            assigned.append(AgentUsageRecord(
                id: record.id,
                provider: record.provider,
                sessionID: sessionID,
                occurredAt: record.occurredAt,
                model: record.model,
                tokens: record.tokens,
                cost: record.cost,
                usageType: record.usageType
            ))
        }
        return assigned
    }

    public static func metadata(
        from records: [AgentUsageRecord],
        attribution: [String: CursorSessionAttribution] = [:]
    ) -> [HistoricalUsageSession] {
        Dictionary(grouping: records.filter { $0.provider == .cursor }, by: \.sessionID).compactMap { sessionID, group in
            let ordered = group.sorted { $0.occurredAt < $1.occurredAt }
            guard let first = ordered.first, let last = ordered.last else { return nil }
            let models = ordered.compactMap(\.model)
            let attr = attribution[Self.conversationKey(sessionID)]
                ?? attribution[sessionID]
            return HistoricalUsageSession(
                provider: .cursor,
                sessionID: sessionID,
                projectName: attr?.projectName,
                title: attr?.title ?? models.first,
                startedAt: first.occurredAt,
                lastActivityAt: last.occurredAt,
                model: models.first,
                projectPath: attr?.projectPath
            )
        }
    }

    public static func conversationKey(_ sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("conv:") {
            return String(trimmed.dropFirst(5))
        }
        return trimmed
    }
}

public struct UsageSourceHealth: Sendable, Equatable {
    public enum State: String, Sendable { case healthy, stale, unavailable }
    public let provider: UsageProvider
    public let state: State
    public let updatedAt: Date?
    public let detail: String?
}

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

public enum BundledPricing {
    /// Pricing snapshot ported from CodexBar's MIT CostUsage catalog. Rates
    /// are API-equivalent USD/token and are intentionally release-versioned.
    public static let version = "2026-07-23"

    public struct ResolvedRates: Equatable, Sendable {
        public let input: Double
        public let cachedInput: Double?
        public let cacheCreation: Double?
        public let output: Double
    }

    /// JSON-friendly catalog row for the Providers → Pricing panel.
    /// Rates are USD per 1M tokens (API-equivalent), matching Analytics model cards.
    public struct CatalogEntry: Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let provider: UsageProvider
        public let inputPerMillionUSD: Double
        public let outputPerMillionUSD: Double
        public let cacheReadPerMillionUSD: Double?
        public let cacheWritePerMillionUSD: Double?
        public let contextThreshold: Int?
        public let inputAboveThresholdPerMillionUSD: Double?
        public let outputAboveThresholdPerMillionUSD: Double?
        public let cacheReadAboveThresholdPerMillionUSD: Double?
        public let cacheWriteAboveThresholdPerMillionUSD: Double?
    }

    private struct Rates {
        let input: Double
        let cachedInput: Double?
        let cacheCreation: Double?
        let output: Double
        let threshold: Int?
        let inputAboveThreshold: Double?
        let cachedInputAboveThreshold: Double?
        let cacheCreationAboveThreshold: Double?
        let outputAboveThreshold: Double?
    }

    private static let codexRates: [String: Rates] = [
        "gpt-5": .init(input: 1.25e-6, cachedInput: 1.25e-7, cacheCreation: nil, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5-codex": .init(input: 1.25e-6, cachedInput: 1.25e-7, cacheCreation: nil, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5-mini": .init(input: 2.5e-7, cachedInput: 2.5e-8, cacheCreation: nil, output: 2e-6, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5-nano": .init(input: 5e-8, cachedInput: 5e-9, cacheCreation: nil, output: 4e-7, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5-pro": .init(input: 1.5e-5, cachedInput: nil, cacheCreation: nil, output: 1.2e-4, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.1": .init(input: 1.25e-6, cachedInput: 1.25e-7, cacheCreation: nil, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.1-codex": .init(input: 1.25e-6, cachedInput: 1.25e-7, cacheCreation: nil, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.1-codex-max": .init(input: 1.25e-6, cachedInput: 1.25e-7, cacheCreation: nil, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.1-codex-mini": .init(input: 2.5e-7, cachedInput: 2.5e-8, cacheCreation: nil, output: 2e-6, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.2": .init(input: 1.75e-6, cachedInput: 1.75e-7, cacheCreation: nil, output: 1.4e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.2-codex": .init(input: 1.75e-6, cachedInput: 1.75e-7, cacheCreation: nil, output: 1.4e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.3-codex": .init(input: 1.75e-6, cachedInput: 1.75e-7, cacheCreation: nil, output: 1.4e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.3-codex-spark": .init(input: 0, cachedInput: 0, cacheCreation: 0, output: 0, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.4": .init(input: 2.5e-6, cachedInput: 2.5e-7, cacheCreation: nil, output: 1.5e-5, threshold: 272_000, inputAboveThreshold: 5e-6, cachedInputAboveThreshold: 5e-7, cacheCreationAboveThreshold: nil, outputAboveThreshold: 2.25e-5),
        "gpt-5.4-mini": .init(input: 7.5e-7, cachedInput: 7.5e-8, cacheCreation: nil, output: 4.5e-6, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.4-nano": .init(input: 2e-7, cachedInput: 2e-8, cacheCreation: nil, output: 1.25e-6, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.4-pro": .init(input: 3e-5, cachedInput: nil, cacheCreation: nil, output: 1.8e-4, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.5": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: nil, output: 3e-5, threshold: 272_000, inputAboveThreshold: 1e-5, cachedInputAboveThreshold: 1e-6, cacheCreationAboveThreshold: nil, outputAboveThreshold: 4.5e-5),
        "gpt-5.5-pro": .init(input: 3e-5, cachedInput: nil, cacheCreation: nil, output: 1.8e-4, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.6-sol": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 3e-5, threshold: 272_000, inputAboveThreshold: 1e-5, cachedInputAboveThreshold: 1e-6, cacheCreationAboveThreshold: 1.25e-5, outputAboveThreshold: 4.5e-5),
        "gpt-5.6-terra": .init(input: 2.5e-6, cachedInput: 2.5e-7, cacheCreation: 3.125e-6, output: 1.5e-5, threshold: 272_000, inputAboveThreshold: 5e-6, cachedInputAboveThreshold: 5e-7, cacheCreationAboveThreshold: 6.25e-6, outputAboveThreshold: 2.25e-5),
        "gpt-5.6-luna": .init(input: 1e-6, cachedInput: 1e-7, cacheCreation: 1.25e-6, output: 6e-6, threshold: 272_000, inputAboveThreshold: 2e-6, cachedInputAboveThreshold: 2e-7, cacheCreationAboveThreshold: 2.5e-6, outputAboveThreshold: 9e-6),
    ]

    private static let claudeRates: [String: Rates] = [
        "claude-fable-5": .init(input: 1e-5, cachedInput: 1e-6, cacheCreation: 1.25e-5, output: 5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-haiku-4-5": .init(input: 1e-6, cachedInput: 1e-7, cacheCreation: 1.25e-6, output: 5e-6, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4": .init(input: 1.5e-5, cachedInput: 1.5e-6, cacheCreation: 1.875e-5, output: 7.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4-1": .init(input: 1.5e-5, cachedInput: 1.5e-6, cacheCreation: 1.875e-5, output: 7.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4-5": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 2.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4-6": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 2.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4-7": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 2.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4-8": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 2.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-sonnet-4": .init(input: 3e-6, cachedInput: 3e-7, cacheCreation: 3.75e-6, output: 1.5e-5, threshold: 200_000, inputAboveThreshold: 6e-6, cachedInputAboveThreshold: 6e-7, cacheCreationAboveThreshold: 7.5e-6, outputAboveThreshold: 2.25e-5),
        "claude-sonnet-4-5": .init(input: 3e-6, cachedInput: 3e-7, cacheCreation: 3.75e-6, output: 1.5e-5, threshold: 200_000, inputAboveThreshold: 6e-6, cachedInputAboveThreshold: 6e-7, cacheCreationAboveThreshold: 7.5e-6, outputAboveThreshold: 2.25e-5),
        "claude-sonnet-4-6": .init(input: 3e-6, cachedInput: 3e-7, cacheCreation: 3.75e-6, output: 1.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
    ]

    // Claude removed the long-context surcharge for these model families in
    // March 2026. Historical records must retain the rate active at use time.
    private static let claudeFullContextStandardPricingCutoff = Date(timeIntervalSince1970: 1_773_360_000)
    private static let claudeHistoricalLongContextRates: [String: Rates] = [
        "claude-opus-4-6": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 2.5e-5, threshold: 200_000, inputAboveThreshold: 1e-5, cachedInputAboveThreshold: 1e-6, cacheCreationAboveThreshold: 1.25e-5, outputAboveThreshold: 3.75e-5),
        "claude-sonnet-4-6": .init(input: 3e-6, cachedInput: 3e-7, cacheCreation: 3.75e-6, output: 1.5e-5, threshold: 200_000, inputAboveThreshold: 6e-6, cachedInputAboveThreshold: 6e-7, cacheCreationAboveThreshold: 7.5e-6, outputAboveThreshold: 2.25e-5),
    ]

    /// API-equivalent calculated cost. Unknown models remain visible but are
    /// intentionally unpriced instead of inheriting a neighbouring model.
    public static func cost(model: String?, tokens: UsageTokenBreakdown, occurredAt: Date? = nil) -> UsageCost {
        guard let rawModel = model?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !rawModel.isEmpty else {
            return UsageCost(usd: nil, provenance: .unavailable)
        }
        let claudeModel = normalizeClaudeModel(rawModel)
        if let rates = claudeRates[claudeModel] {
            if let occurredAt, occurredAt < claudeFullContextStandardPricingCutoff,
               let historicalRates = claudeHistoricalLongContextRates[claudeModel]
            {
                return calculated(claudeCost(rates: historicalRates, tokens: tokens), version: version)
            }
            return calculated(claudeCost(rates: rates, tokens: tokens), version: version)
        }
        if let rates = codexRates[normalizeCodexModel(rawModel)] {
            return calculated(codexCost(rates: rates, tokens: tokens), version: version)
        }
        return UsageCost(usd: nil, provenance: .unavailable)
    }

    /// Catalog rates for Analytics model cards. Returns nil for unknown models
    /// (shown as "fallback price" in the UI).
    public static func resolved(model: String?) -> ResolvedRates? {
        guard let rawModel = model?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !rawModel.isEmpty else {
            return nil
        }
        let rates = claudeRates[normalizeClaudeModel(rawModel)] ?? codexRates[normalizeCodexModel(rawModel)]
        guard let rates else { return nil }
        return ResolvedRates(input: rates.input, cachedInput: rates.cachedInput, cacheCreation: rates.cacheCreation, output: rates.output)
    }

    /// Approximate dollars saved by reading cache instead of paying full input
    /// (ccgauge `saved` = cache_read * (input - cacheRead)).
    public static func cacheSavingsUSD(model: String?, tokens: UsageTokenBreakdown) -> Double {
        guard let rates = resolved(model: model), tokens.cachedInput > 0 else { return 0 }
        let cacheRate = rates.cachedInput ?? rates.input
        return max(0, Double(tokens.cachedInput) * (rates.input - cacheRate))
    }

    public static func shortDisplayName(_ model: String) -> String {
        var value = model
        if value.hasPrefix("openai/") { value = String(value.dropFirst("openai/".count)) }
        if value.hasPrefix("anthropic.") { value = String(value.dropFirst("anthropic.".count)) }
        if let range = value.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            value = String(value[..<range.lowerBound])
        }
        if let range = value.range(of: #"-\d{8}$"#, options: .regularExpression) {
            value = String(value[..<range.lowerBound])
        }
        return value
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part -> String in
                let text = String(part)
                if text.lowercased().hasPrefix("gpt") { return text.uppercased() }
                return text.prefix(1).uppercased() + text.dropFirst()
            }
            .joined(separator: " ")
    }

    /// Full Claude/Codex rate catalog used for local cost calculation.
    /// Cursor has no local rates (provider-reported `chargedCents`).
    public static func catalog(provider: UsageProvider? = nil) -> [CatalogEntry] {
        var entries: [CatalogEntry] = []
        if provider == nil || provider == .claude {
            entries.append(contentsOf: claudeRates.keys.sorted().map { catalogEntry(id: $0, provider: .claude, rates: claudeRates[$0]!) })
        }
        if provider == nil || provider == .codex {
            entries.append(contentsOf: codexRates.keys.sorted().map { catalogEntry(id: $0, provider: .codex, rates: codexRates[$0]!) })
        }
        return entries
    }

    private static func catalogEntry(id: String, provider: UsageProvider, rates: Rates) -> CatalogEntry {
        CatalogEntry(
            id: id,
            displayName: shortDisplayName(id),
            provider: provider,
            inputPerMillionUSD: rates.input * 1_000_000,
            outputPerMillionUSD: rates.output * 1_000_000,
            cacheReadPerMillionUSD: rates.cachedInput.map { $0 * 1_000_000 },
            cacheWritePerMillionUSD: rates.cacheCreation.map { $0 * 1_000_000 },
            contextThreshold: rates.threshold,
            inputAboveThresholdPerMillionUSD: rates.inputAboveThreshold.map { $0 * 1_000_000 },
            outputAboveThresholdPerMillionUSD: rates.outputAboveThreshold.map { $0 * 1_000_000 },
            cacheReadAboveThresholdPerMillionUSD: rates.cachedInputAboveThreshold.map { $0 * 1_000_000 },
            cacheWriteAboveThresholdPerMillionUSD: rates.cacheCreationAboveThreshold.map { $0 * 1_000_000 }
        )
    }

    private static func calculated(_ value: Double, version: String) -> UsageCost {
        UsageCost(usd: value, provenance: .calculated, pricingVersion: version)
    }

    private static func codexCost(rates: Rates, tokens: UsageTokenBreakdown) -> Double {
        let totalInput = tokens.input
        let cached = min(tokens.cachedInput, totalInput)
        let cacheCreation = min(tokens.cacheCreation, totalInput - cached)
        let normal = totalInput - cached - cacheCreation
        let longContext = rates.threshold.map { totalInput > $0 } ?? false
        let inputRate = longContext ? rates.inputAboveThreshold ?? rates.input : rates.input
        let cachedRate = longContext ? rates.cachedInputAboveThreshold ?? rates.cachedInput ?? inputRate : rates.cachedInput ?? rates.input
        let creationRate = longContext ? rates.cacheCreationAboveThreshold ?? rates.cacheCreation ?? inputRate : rates.cacheCreation ?? rates.input
        let outputRate = longContext ? rates.outputAboveThreshold ?? rates.output : rates.output
        return Double(normal) * inputRate + Double(cached) * cachedRate + Double(cacheCreation) * creationRate + Double(tokens.output) * outputRate
    }

    private static func claudeCost(rates: Rates, tokens: UsageTokenBreakdown) -> Double {
        let longContext = rates.threshold.map { tokens.input + tokens.cachedInput + tokens.cacheCreation > $0 } ?? false
        let inputRate = longContext ? rates.inputAboveThreshold ?? rates.input : rates.input
        let cachedRate = longContext ? rates.cachedInputAboveThreshold ?? rates.cachedInput ?? inputRate : rates.cachedInput ?? rates.input
        let creationRate = longContext ? rates.cacheCreationAboveThreshold ?? rates.cacheCreation ?? inputRate : rates.cacheCreation ?? rates.input
        let creation1h = min(tokens.cacheCreation1h, tokens.cacheCreation)
        return Double(tokens.input) * inputRate
            + Double(tokens.cachedInput) * cachedRate
            + Double(tokens.cacheCreation - creation1h) * creationRate
            + Double(creation1h) * inputRate * 2
            + Double(tokens.output) * (longContext ? rates.outputAboveThreshold ?? rates.output : rates.output)
    }

    private static func normalizeCodexModel(_ model: String) -> String {
        var model = model.hasPrefix("openai/") ? String(model.dropFirst("openai/".count)) : model
        if model == "gpt-5.6" { return "gpt-5.6-sol" }
        if let dateRange = model.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(model[..<dateRange.lowerBound])
            if codexRates[base] != nil { model = base }
        }
        return model
    }

    private static func normalizeClaudeModel(_ model: String) -> String {
        var model = model.hasPrefix("anthropic.") ? String(model.dropFirst("anthropic.".count)) : model
        if let dot = model.lastIndex(of: ".") {
            let tail = String(model[model.index(after: dot)...])
            if tail.hasPrefix("claude-") { model = tail }
        }
        if let versionRange = model.range(of: #"-v\d+:\d+$"#, options: .regularExpression) { model.removeSubrange(versionRange) }
        if let dateRange = model.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(model[..<dateRange.lowerBound])
            if claudeRates[base] != nil { model = base }
        }
        return model
    }
}

public final class UsageStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw UsageStoreError.open }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS usage_records (source_key TEXT PRIMARY KEY, provider TEXT NOT NULL, session_id TEXT NOT NULL, occurred_at REAL NOT NULL, model TEXT, input_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL, cache_creation_tokens INTEGER NOT NULL DEFAULT 0, cache_creation_1h_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL, reasoning_tokens INTEGER NOT NULL, cost_usd REAL, provenance TEXT NOT NULL, pricing_version TEXT, budget_eligible INTEGER NOT NULL, usage_type TEXT)")
        // Existing installations have the original narrower token schema.
        // These migrations retain their historical rows with zero cache writes.
        try? execute("ALTER TABLE usage_records ADD COLUMN cache_creation_tokens INTEGER NOT NULL DEFAULT 0")
        try? execute("ALTER TABLE usage_records ADD COLUMN cache_creation_1h_tokens INTEGER NOT NULL DEFAULT 0")
        try? execute("ALTER TABLE usage_records ADD COLUMN usage_type TEXT")
        try execute("CREATE TABLE IF NOT EXISTS usage_sessions (provider TEXT NOT NULL, session_id TEXT NOT NULL, project_name TEXT, title TEXT, started_at REAL NOT NULL, last_activity_at REAL NOT NULL, model TEXT, source_revision TEXT NOT NULL, PRIMARY KEY(provider, session_id))")
        try? execute("ALTER TABLE usage_sessions ADD COLUMN project_path TEXT")
        try? execute("INSERT OR IGNORE INTO usage_sessions (provider,session_id,project_name,title,started_at,last_activity_at,model,source_revision) SELECT provider,session_id,project_name,title,started_at,last_activity_at,model,'\(LocalUsageSource.historicalParserRevision)' FROM historical_usage_sessions")
        try execute("CREATE TABLE IF NOT EXISTS usage_source_checkpoints (source_key TEXT PRIMARY KEY, updated_at REAL NOT NULL, state TEXT NOT NULL, detail TEXT)")
        try execute("DELETE FROM usage_source_checkpoints WHERE state = 'historical-usage-receipt' AND detail NOT LIKE '%\(LocalUsageSource.historicalParserRevision)%'")
        try execute("CREATE TABLE IF NOT EXISTS budget_alert_receipts (receipt_key TEXT PRIMARY KEY, created_at REAL NOT NULL)")
    }

    deinit { sqlite3_close(database) }

    public func upsert(_ records: [AgentUsageRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !records.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO usage_records (source_key,provider,session_id,occurred_at,model,input_tokens,cached_input_tokens,cache_creation_tokens,cache_creation_1h_tokens,output_tokens,reasoning_tokens,cost_usd,provenance,pricing_version,budget_eligible,usage_type) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(record.id, at: 1, statement); bind(record.provider.rawValue, at: 2, statement); bind(record.sessionID, at: 3, statement)
                sqlite3_bind_double(statement, 4, record.occurredAt.timeIntervalSince1970)
                bind(record.model, at: 5, statement)
                sqlite3_bind_int64(statement, 6, Int64(record.tokens.input)); sqlite3_bind_int64(statement, 7, Int64(record.tokens.cachedInput)); sqlite3_bind_int64(statement, 8, Int64(record.tokens.cacheCreation)); sqlite3_bind_int64(statement, 9, Int64(record.tokens.cacheCreation1h)); sqlite3_bind_int64(statement, 10, Int64(record.tokens.output)); sqlite3_bind_int64(statement, 11, Int64(record.tokens.reasoning))
                if let cost = record.cost.usd { sqlite3_bind_double(statement, 12, cost) } else { sqlite3_bind_null(statement, 12) }
                bind(record.cost.provenance.rawValue, at: 13, statement); bind(record.cost.pricingVersion, at: 14, statement); sqlite3_bind_int(statement, 15, record.cost.isBudgetEligible ? 1 : 0)
                bind(record.usageType?.rawValue, at: 16, statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Replaces every stored row for a provider. Used for Cursor's live usage-events
    /// ledger so progressive token updates cannot accumulate under unstable keys.
    public func replaceRecords(provider: UsageProvider, with records: [AgentUsageRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            var delete: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM usage_records WHERE provider = ?", -1, &delete, nil) == SQLITE_OK else {
                throw UsageStoreError.statement
            }
            defer { sqlite3_finalize(delete) }
            bind(provider.rawValue, at: 1, delete)
            guard sqlite3_step(delete) == SQLITE_DONE else { throw UsageStoreError.statement }

            if !records.isEmpty {
                var statement: OpaquePointer?
                let sql = "INSERT OR REPLACE INTO usage_records (source_key,provider,session_id,occurred_at,model,input_tokens,cached_input_tokens,cache_creation_tokens,cache_creation_1h_tokens,output_tokens,reasoning_tokens,cost_usd,provenance,pricing_version,budget_eligible,usage_type) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }
                defer { sqlite3_finalize(statement) }
                for record in records {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    bind(record.id, at: 1, statement); bind(record.provider.rawValue, at: 2, statement); bind(record.sessionID, at: 3, statement)
                    sqlite3_bind_double(statement, 4, record.occurredAt.timeIntervalSince1970)
                    bind(record.model, at: 5, statement)
                    sqlite3_bind_int64(statement, 6, Int64(record.tokens.input)); sqlite3_bind_int64(statement, 7, Int64(record.tokens.cachedInput)); sqlite3_bind_int64(statement, 8, Int64(record.tokens.cacheCreation)); sqlite3_bind_int64(statement, 9, Int64(record.tokens.cacheCreation1h)); sqlite3_bind_int64(statement, 10, Int64(record.tokens.output)); sqlite3_bind_int64(statement, 11, Int64(record.tokens.reasoning))
                    if let cost = record.cost.usd { sqlite3_bind_double(statement, 12, cost) } else { sqlite3_bind_null(statement, 12) }
                    bind(record.cost.provenance.rawValue, at: 13, statement); bind(record.cost.pricingVersion, at: 14, statement); sqlite3_bind_int(statement, 15, record.cost.isBudgetEligible ? 1 : 0)
                    bind(record.usageType?.rawValue, at: 16, statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func records(matching query: UsageQuery = .init()) throws -> [AgentUsageRecord] {
        lock.lock(); defer { lock.unlock() }
        var clauses: [String] = []; var values: [Any] = []
        if let providers = query.providers, !providers.isEmpty { clauses.append("provider IN (\(providers.map { _ in "?" }.joined(separator: ",")))"); values += providers.map(\.rawValue) }
        if let start = query.startDate { clauses.append("occurred_at >= ?"); values.append(start.timeIntervalSince1970) }
        if let end = query.endDate { clauses.append("occurred_at < ?"); values.append(end.timeIntervalSince1970) }
        if let sessionID = query.sessionID { clauses.append("session_id = ?"); values.append(sessionID) }
        let sql = "SELECT source_key,provider,session_id,occurred_at,model,input_tokens,cached_input_tokens,cache_creation_tokens,cache_creation_1h_tokens,output_tokens,reasoning_tokens,cost_usd,provenance,pricing_version,budget_eligible,usage_type FROM usage_records\(clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) ORDER BY occurred_at DESC"
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }; defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { if let string = value as? String { bind(string, at: Int32(index + 1), statement) } else if let number = value as? Double { sqlite3_bind_double(statement, Int32(index + 1), number) } }
        var result: [AgentUsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnString(statement, 0), let rawProvider = columnString(statement, 1), let provider = UsageProvider(rawValue: rawProvider), let session = columnString(statement, 2), let provenanceRaw = columnString(statement, 12), let provenance = UsageCostProvenance(rawValue: provenanceRaw) else { continue }
            let model = columnString(statement, 4); let cost = sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 11)
            let usageType = columnString(statement, 15).flatMap(UsageBillingType.init(rawValue:))
            result.append(.init(id: id, provider: provider, sessionID: session, occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), model: model, tokens: .init(input: Int(sqlite3_column_int64(statement, 5)), cachedInput: Int(sqlite3_column_int64(statement, 6)), cacheCreation: Int(sqlite3_column_int64(statement, 7)), cacheCreation1h: Int(sqlite3_column_int64(statement, 8)), output: Int(sqlite3_column_int64(statement, 9)), reasoning: Int(sqlite3_column_int64(statement, 10))), cost: .init(usd: cost, provenance: provenance, pricingVersion: columnString(statement, 13), isBudgetEligible: sqlite3_column_int(statement, 14) != 0), usageType: usageType))
        }
        return result
    }

    public func upsert(sessions: [HistoricalUsageSession]) throws {
        lock.lock(); defer { lock.unlock() }
        for session in sessions {
            try upsertSessionLocked(session)
        }
    }

    /// Replaces all session metadata rows for a provider. Used for Cursor so
    /// local workspace attribution can overwrite stale `"Cursor"` placeholders.
    public func replaceSessions(provider: UsageProvider, with sessions: [HistoricalUsageSession]) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            var delete: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM usage_sessions WHERE provider = ?", -1, &delete, nil) == SQLITE_OK else {
                throw UsageStoreError.statement
            }
            defer { sqlite3_finalize(delete) }
            bind(provider.rawValue, at: 1, delete)
            guard sqlite3_step(delete) == SQLITE_DONE else { throw UsageStoreError.statement }
            for session in sessions where session.provider == provider {
                try upsertSessionLocked(session)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func upsertSessionLocked(_ session: HistoricalUsageSession) throws {
        let sql = """
            INSERT INTO usage_sessions (provider,session_id,project_name,title,started_at,last_activity_at,model,source_revision,project_path)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(provider,session_id) DO UPDATE SET
                project_name=COALESCE(usage_sessions.project_name,excluded.project_name),
                project_path=COALESCE(usage_sessions.project_path,excluded.project_path),
                title=COALESCE(excluded.title,usage_sessions.title),
                started_at=MIN(usage_sessions.started_at,excluded.started_at),
                last_activity_at=MAX(usage_sessions.last_activity_at,excluded.last_activity_at),
                model=CASE WHEN excluded.last_activity_at > usage_sessions.last_activity_at
                    THEN COALESCE(excluded.model,usage_sessions.model)
                    ELSE COALESCE(usage_sessions.model,excluded.model) END,
                source_revision=excluded.source_revision
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }
        defer { sqlite3_finalize(statement) }
        bind(session.provider.rawValue, at: 1, statement); bind(session.sessionID, at: 2, statement)
        bind(session.projectName, at: 3, statement); bind(session.title, at: 4, statement)
        sqlite3_bind_double(statement, 5, session.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, session.lastActivityAt.timeIntervalSince1970)
        bind(session.model, at: 7, statement)
        bind(session.sourceRevision, at: 8, statement)
        bind(session.projectPath, at: 9, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
    }

    public func upsert(_ scan: HistoricalUsageScan) throws {
        try upsert(scan.records)
        try upsert(sessions: scan.sessions)
        try save(sourceReceipts: scan.sourceReceipts)
    }

    public func sessions(matching query: HistoricalUsageSessionQuery = .init()) throws -> [HistoricalUsageSession] {
        lock.lock(); defer { lock.unlock() }
        var clauses: [String] = []; var values: [Any] = []
        if let providers = query.providers, !providers.isEmpty { clauses.append("provider IN (\(providers.map { _ in "?" }.joined(separator: ",")))"); values += providers.map(\.rawValue) }
        if let start = query.startDate { clauses.append("last_activity_at >= ?"); values.append(start.timeIntervalSince1970) }
        if let end = query.endDate { clauses.append("last_activity_at < ?"); values.append(end.timeIntervalSince1970) }
        if let sessionID = query.sessionID { clauses.append("session_id = ?"); values.append(sessionID) }
        let sql = "SELECT provider,session_id,project_name,title,started_at,last_activity_at,model,source_revision,project_path FROM usage_sessions\(clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) ORDER BY last_activity_at DESC"
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }; defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { if let string = value as? String { bind(string, at: Int32(index + 1), statement) } else if let number = value as? Double { sqlite3_bind_double(statement, Int32(index + 1), number) } }
        var result: [HistoricalUsageSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawProvider = columnString(statement, 0), let provider = UsageProvider(rawValue: rawProvider), let sessionID = columnString(statement, 1) else { continue }
            result.append(.init(provider: provider, sessionID: sessionID, projectName: columnString(statement, 2), title: columnString(statement, 3), startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)), lastActivityAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)), model: columnString(statement, 6), sourceRevision: columnString(statement, 7) ?? LocalUsageSource.historicalParserRevision, projectPath: columnString(statement, 8)))
        }
        return result
    }

    public func save(sourceReceipts: [HistoricalUsageSourceReceipt]) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        for receipt in sourceReceipts {
            guard let detail = String(data: try encoder.encode(receipt), encoding: .utf8) else { throw UsageStoreError.statement }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO usage_source_checkpoints (source_key,updated_at,state,detail) VALUES (?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }
            defer { sqlite3_finalize(statement) }
            bind(receipt.sourceKey, at: 1, statement); sqlite3_bind_double(statement, 2, receipt.modifiedAt.timeIntervalSince1970)
            bind("historical-usage-receipt", at: 3, statement); bind(detail, at: 4, statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
        }
    }

    /// Returns only source files whose mtime, size, or parser revision differs
    /// from the receipt persisted by a prior historical scan.
    public func changedSources(_ receipts: [HistoricalUsageSourceReceipt]) throws -> [HistoricalUsageSourceReceipt] {
        lock.lock(); defer { lock.unlock() }
        let decoder = JSONDecoder()
        return try receipts.filter { receipt in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT detail FROM usage_source_checkpoints WHERE source_key = ? AND state = ?", -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }
            defer { sqlite3_finalize(statement) }
            bind(receipt.sourceKey, at: 1, statement); bind("historical-usage-receipt", at: 2, statement)
            guard sqlite3_step(statement) == SQLITE_ROW, let detail = columnString(statement, 0), let data = detail.data(using: .utf8), let saved = try? decoder.decode(HistoricalUsageSourceReceipt.self, from: data) else { return true }
            return saved != receipt
        }
    }

    public func aggregate(_ query: UsageQuery = .init()) throws -> UsageAggregate { UsageAggregate(records: try records(matching: query)) }

    public func saveReceipt(_ receipt: BudgetAlertReceipt) throws {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO budget_alert_receipts (receipt_key,created_at) VALUES (?,?)", -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }; defer { sqlite3_finalize(statement) }
        bind(receipt.key, at: 1, statement); sqlite3_bind_double(statement, 2, receipt.createdAt.timeIntervalSince1970); guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
    }

    public func hasReceipt(_ key: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, "SELECT 1 FROM budget_alert_receipts WHERE receipt_key = ?", -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }; defer { sqlite3_finalize(statement) }; bind(key, at: 1, statement); return sqlite3_step(statement) == SQLITE_ROW
    }

    private func execute(_ sql: String) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw UsageStoreError.statement } }
    private func bind(_ value: String?, at index: Int32, _ statement: OpaquePointer?) { guard let value else { sqlite3_bind_null(statement, index); return }; sqlite3_bind_text(statement, index, value, -1, sqliteTransient) }
}

public enum UsageStoreError: Error { case open, statement }
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? { sqlite3_column_text(statement, index).map { String(cString: $0) } }

func sanitizedSessionTitle(_ value: String?) -> String? {
    value?
        .split(whereSeparator: \ .isWhitespace)
        .joined(separator: " ")
        .prefix(80)
        .description
        .nilIfEmpty
}

func sanitizedProjectName(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
        .split(whereSeparator: { $0 == "/" || $0 == "\\" })
        .last?
        .description
        .nilIfEmpty
}

func sanitizedProjectPath(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    if value == "(unknown)" { return value }
    // Keep local cwd for Analytics project cards; strip trailing separators only.
    var path = value
    while path.count > 1, path.hasSuffix("/") || path.hasSuffix("\\") {
        path.removeLast()
    }
    return path.nilIfEmpty
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum LocalUsageSource {
    /// Bump when Claude/Codex JSONL → ledger mapping changes so receipts
    /// invalidate and UsageCoordinator can rebuild provider rows cleanly.
    public static let historicalParserRevision = "historical-sessions-v3+claude-stream-dedup"

    public static func codexRecords(root: URL, now: Date = .now) -> [AgentUsageRecord] {
        codexScan(root: root, now: now).records
    }

    public static func claudeRecords(roots: [URL], now: Date = .now) -> [AgentUsageRecord] {
        claudeScan(roots: roots, now: now).records
    }

    /// Finds the standard Claude Code projects directory, or an explicit
    /// comma-separated `CLAUDE_CONFIG_DIR` override. The explicit-root overload
    /// remains available for app configuration and tests.
    public static func claudeRecords(now: Date = .now, environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentUsageRecord] {
        claudeScan(roots: resolvedClaudeRoots(environment: environment, homeDirectory: homeDirectory), now: now).records
    }

    public static func resolvedClaudeRoots(environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let roots: [URL]
        if let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            roots = configured.split(separator: ",").map { raw in
                let url = URL(fileURLWithPath: String(raw).trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL
                return url.lastPathComponent == "projects" ? url : url.appendingPathComponent("projects", isDirectory: true)
            }
        } else {
            roots = [
                homeDirectory.appendingPathComponent(".config/claude/projects", isDirectory: true),
                homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
            ]
        }
        return uniqueRoots(roots)
    }

    /// Kept as a source-compatible no-op while Cursor accounting moves to its
    /// authenticated usage-events connector. Local SQLite context values are
    /// not authoritative token or cost records and must never reach the ledger.
    @available(*, deprecated, message: "Use the authenticated Cursor usage-events connector.")
    public static func cursorEstimatedRecords(databaseURL: URL, now: Date = .now) -> [AgentUsageRecord] {
        []
    }

    public static func codexSourceFiles(root: URL) -> [URL] {
        // ccusage / CodexBar: scan live + archived, but never bill the same
        // rollout basename twice when Codex copies a session into archived_sessions.
        let live = jsonlFiles(in: root.appendingPathComponent("sessions", isDirectory: true))
        let archived = jsonlFiles(in: root.appendingPathComponent("archived_sessions", isDirectory: true))
        var byBasename: [String: URL] = [:]
        for file in archived + live {
            byBasename[file.lastPathComponent.lowercased()] = file
        }
        return uniqueFiles(Array(byBasename.values))
    }

    public static func claudeSourceFiles(roots: [URL]) -> [URL] {
        uniqueFiles(uniqueRoots(roots).flatMap { jsonlFiles(in: $0) })
    }

    public static func sourceReceipts(for files: [URL], parserRevision: String = historicalParserRevision) -> [HistoricalUsageSourceReceipt] {
        uniqueFiles(files).compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let modifiedAt = values.contentModificationDate else { return nil }
            return .init(sourceKey: sourceIdentity(for: file), fileSize: Int64(values.fileSize ?? 0), modifiedAt: modifiedAt, parserRevision: parserRevision)
        }
    }

    public static func sourceIdentity(for file: URL) -> String {
        SHA256.hash(data: Data(file.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func codexScan(root: URL, now: Date = .now) -> HistoricalUsageScan {
        codexScan(files: codexSourceFiles(root: root), now: now)
    }

    public static func codexScan(files: [URL], now: Date = .now) -> HistoricalUsageScan {
        combine(files.map { parseCodex(file: $0, fallbackDate: fallbackDate(for: $0, now: now)) }, receipts: sourceReceipts(for: files))
    }

    public static func claudeScan(roots: [URL], now: Date = .now) -> HistoricalUsageScan {
        claudeScan(files: claudeSourceFiles(roots: roots), now: now)
    }

    public static func claudeScan(files: [URL], now: Date = .now) -> HistoricalUsageScan {
        combine(files.map { parseClaude(file: $0, fallbackDate: fallbackDate(for: $0, now: now)) }, receipts: sourceReceipts(for: files))
    }

    private static func parseCodex(file: URL, fallbackDate: Date) -> HistoricalUsageScan {
        var sessionID = file.deletingPathExtension().lastPathComponent
        var projectName: String?
        var projectPath: String?
        var title: String?
        var model: String?
        var startedAt = fallbackDate
        var lastActivityAt = fallbackDate
        var sawEvent = false
        var previousTotal: UsageTokenBreakdown?
        var records: [AgentUsageRecord] = []

        forEachJSONObject(in: file) { line, object in
            let payload = object["payload"] as? [String: Any] ?? [:]
            let occurredAt = date(object["timestamp"]) ?? date(payload["timestamp"]) ?? fallbackDate
            if !sawEvent {
                startedAt = occurredAt
                lastActivityAt = occurredAt
                sawEvent = true
            } else {
                lastActivityAt = max(lastActivityAt, occurredAt)
            }
            if model == nil { model = modelName(in: payload) }
            let recordType = string(object["type"]) ?? (string(payload["type"]) == "token_count" ? "event_msg" : nil)
            switch recordType {
            case "session_meta":
                sessionID = string(payload["id"]) ?? sessionID
                if let cwd = string(payload["cwd"]) {
                    projectPath = sanitizedProjectPath(cwd) ?? projectPath
                    projectName = sanitizedProjectName(cwd) ?? projectName
                }
                if let timestamp = date(payload["timestamp"]) { startedAt = min(startedAt, timestamp) }
            case "turn_context":
                if let cwd = string(payload["cwd"]) {
                    projectPath = sanitizedProjectPath(cwd) ?? projectPath
                    projectName = sanitizedProjectName(cwd) ?? projectName
                }
                model = string(payload["model"]) ?? model
            case "event_msg":
                guard let eventType = string(payload["type"]) else { return }
                if eventType == "user_message" {
                    if title == nil, let candidate = messageText(payload), !isSyntheticUserText(candidate) { title = candidate }
                    return
                }
                guard eventType == "token_count", let info = payload["info"] as? [String: Any] else { return }
                let totals = info["total_token_usage"] as? [String: Any]
                let last = info["last_token_usage"] as? [String: Any]
                let delta: UsageTokenBreakdown?
                if let totals {
                    let current = tokenBreakdown(totals)
                    delta = cumulativeDelta(current, previous: previousTotal)
                    previousTotal = maximum(previousTotal ?? .init(), current)
                } else if let last {
                    let current = tokenBreakdown(last)
                    delta = current.total > 0 ? current : nil
                    previousTotal = add(previousTotal ?? .init(), current)
                } else { delta = nil }
                guard let delta, delta.total > 0 else { return }
                let recordModel = modelName(in: info) ?? model
                records.append(.init(id: "codex:\(sessionID):\(line)", provider: .codex, sessionID: sessionID, occurredAt: occurredAt, model: recordModel, tokens: delta, cost: BundledPricing.cost(model: recordModel, tokens: delta, occurredAt: occurredAt)))
            default: break
            }
        }
        let session = HistoricalUsageSession(provider: .codex, sessionID: sessionID, projectName: projectName, title: title, startedAt: startedAt, lastActivityAt: lastActivityAt, model: model, projectPath: projectPath)
        return .init(records: records, sessions: sawEvent ? [session] : [])
    }

    private static func parseClaude(file: URL, fallbackDate: Date) -> HistoricalUsageScan {
        let parentSessionID = parentSessionID(fromSubagentPath: file.path)
        var sessionID = parentSessionID ?? file.deletingPathExtension().lastPathComponent
        var projectName: String?
        var projectPath: String?
        var title: String?
        var hasAITitle = false
        var model: String?
        var startedAt = fallbackDate
        var lastActivityAt = fallbackDate
        var sawEvent = false
        // Claude Code streams multiple assistant JSONL rows per API response that
        // share message.id + requestId while output_tokens grow. CodexBar / fixed
        // ccusage keep the final row (last-wins). Keying on uuid over-bills input
        // by the chunk count. ccgauge's earliest-wins under-counts output.
        var keyedRecords: [String: AgentUsageRecord] = [:]
        var unkeyedRecords: [AgentUsageRecord] = []

        forEachJSONObject(in: file) { line, object in
            let occurredAt = date(object["timestamp"]) ?? fallbackDate
            if !sawEvent {
                startedAt = occurredAt
                lastActivityAt = occurredAt
                sawEvent = true
            } else {
                lastActivityAt = max(lastActivityAt, occurredAt)
            }
            let objectSessionID = sessionIdentifier(in: object) ?? sessionIdentifier(in: object["message"] as? [String: Any])
            if parentSessionID == nil { sessionID = objectSessionID ?? sessionID }
            if let cwd = string(object["cwd"]) {
                projectPath = sanitizedProjectPath(cwd) ?? projectPath
                projectName = sanitizedProjectName(cwd) ?? projectName
            }
            let type = string(object["type"])
            if parentSessionID == nil, type == "ai-title", let candidate = string(object["aiTitle"]) ?? string(object["title"]) ?? messageText(object) {
                title = candidate; hasAITitle = true
                return
            }
            if parentSessionID == nil, type == "user", title == nil, !hasAITitle, let candidate = messageText(object), !isSyntheticUserText(candidate), !candidate.isEmpty {
                title = candidate
                return
            }
            guard type == "assistant", let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return }
            let cacheCreation = int(usage["cache_creation_input_tokens"])
            let cacheCreation1h = min(cacheCreation, int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]))
            let tokens = UsageTokenBreakdown(input: int(usage["input_tokens"]), cachedInput: int(usage["cache_read_input_tokens"]), cacheCreation: cacheCreation, cacheCreation1h: cacheCreation1h, output: int(usage["output_tokens"]))
            guard tokens.total > 0 else { return }
            let recordModel = string(message["model"]); model = recordModel ?? model
            let messageID = string(message["id"])
            let requestID = string(object["requestId"])
            let sourceID: String
            let dedupeKey: String?
            if let messageID, let requestID {
                sourceID = "\(messageID):\(requestID)"
                dedupeKey = sourceID
            } else if let messageID {
                // Third-party / older transports omit requestId; message.id alone
                // still collapses repeated JSONL rewrites (ccusage #985).
                sourceID = "mid:\(messageID)"
                dedupeKey = sourceID
            } else if let requestID {
                sourceID = "req:\(requestID)"
                dedupeKey = sourceID
            } else {
                sourceID = string(object["uuid"]) ?? "\(occurredAt.timeIntervalSince1970):\(line)"
                dedupeKey = nil
            }
            let record = AgentUsageRecord(
                id: "claude:\(sessionID):\(sourceID)",
                provider: .claude,
                sessionID: sessionID,
                occurredAt: occurredAt,
                model: recordModel,
                tokens: tokens,
                cost: BundledPricing.cost(model: recordModel, tokens: tokens, occurredAt: occurredAt)
            )
            if let dedupeKey {
                keyedRecords[dedupeKey] = record
            } else {
                unkeyedRecords.append(record)
            }
        }
        let records = Array(keyedRecords.values) + unkeyedRecords
        let session = HistoricalUsageSession(provider: .claude, sessionID: sessionID, projectName: projectName, title: title, startedAt: startedAt, lastActivityAt: lastActivityAt, model: model, projectPath: projectPath)
        return .init(records: records, sessions: sawEvent ? [session] : [])
    }

    private static func jsonlFiles(in root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]))?.flatMap { url -> [URL] in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { return [] }
            if values.isDirectory == true { return jsonlFiles(in: url) }
            return values.isRegularFile == true && url.pathExtension == "jsonl" ? [url] : []
        } ?? []
    }

    private static func uniqueFiles(_ files: [URL]) -> [URL] {
        var paths: Set<String> = []
        return files.map(\.standardizedFileURL).filter {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true && paths.insert($0.path).inserted
        }.sorted { $0.path < $1.path }
    }

    private static func uniqueRoots(_ roots: [URL]) -> [URL] {
        var paths: Set<String> = []
        return roots.map(\.standardizedFileURL).filter { paths.insert($0.path).inserted }
    }
    private static func fallbackDate(for file: URL, now: Date) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
    }
    private static func counterDelta(_ current: Int, previous: Int) -> Int {
        max(current - previous, 0)
    }

    private static func combine(_ scans: [HistoricalUsageScan], receipts: [HistoricalUsageSourceReceipt]) -> HistoricalUsageScan {
        var records: [AgentUsageRecord] = []
        var recordIndexes: [String: Int] = [:]
        var sessions: [String: HistoricalUsageSession] = [:]
        for scan in scans {
            for record in scan.records {
                if let index = recordIndexes[record.id] {
                    records[index] = record
                } else {
                    recordIndexes[record.id] = records.count
                    records.append(record)
                }
            }
            for session in scan.sessions {
                let key = session.id
                guard let existing = sessions[key] else { sessions[key] = session; continue }
                let useIncoming = session.lastActivityAt > existing.lastActivityAt
                sessions[key] = .init(provider: session.provider, sessionID: session.sessionID, projectName: existing.projectName ?? session.projectName, title: existing.title ?? session.title, startedAt: min(existing.startedAt, session.startedAt), lastActivityAt: max(existing.lastActivityAt, session.lastActivityAt), model: useIncoming ? session.model ?? existing.model : existing.model ?? session.model, sourceRevision: useIncoming ? session.sourceRevision : existing.sourceRevision, projectPath: existing.projectPath ?? session.projectPath)
            }
        }
        return .init(records: records, sessions: sessions.values.sorted { $0.lastActivityAt > $1.lastActivityAt }, sourceReceipts: receipts)
    }

    private static func forEachJSONObject(in file: URL, _ body: (Int, [String: Any]) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let maxLineBytes = 512 * 1024
        var pending = Data()
        var lineNumber = 0
        var discardUntilNewline = false
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                lineNumber += 1
                if discardUntilNewline { discardUntilNewline = false; continue }
                guard line.count <= maxLineBytes, let object = try? JSONSerialization.jsonObject(with: line), let dictionary = object as? [String: Any] else { continue }
                body(lineNumber, dictionary)
            }
            if pending.count > maxLineBytes { pending.removeAll(keepingCapacity: true); discardUntilNewline = true }
        }
        if !pending.isEmpty, !discardUntilNewline, pending.count <= maxLineBytes, let object = try? JSONSerialization.jsonObject(with: pending), let dictionary = object as? [String: Any] {
            body(lineNumber + 1, dictionary)
        }
    }

    private static func cumulativeDelta(_ current: UsageTokenBreakdown, previous: UsageTokenBreakdown?) -> UsageTokenBreakdown? {
        guard let previous else { return current.total > 0 ? current : nil }
        let delta = UsageTokenBreakdown(input: counterDelta(current.input, previous: previous.input), cachedInput: counterDelta(current.cachedInput, previous: previous.cachedInput), cacheCreation: counterDelta(current.cacheCreation, previous: previous.cacheCreation), output: counterDelta(current.output, previous: previous.output), reasoning: counterDelta(current.reasoning, previous: previous.reasoning))
        return delta.total > 0 ? delta : nil
    }

    private static func add(_ lhs: UsageTokenBreakdown, _ rhs: UsageTokenBreakdown) -> UsageTokenBreakdown {
        .init(input: lhs.input + rhs.input, cachedInput: lhs.cachedInput + rhs.cachedInput, cacheCreation: lhs.cacheCreation + rhs.cacheCreation, cacheCreation1h: lhs.cacheCreation1h + rhs.cacheCreation1h, output: lhs.output + rhs.output, reasoning: lhs.reasoning + rhs.reasoning)
    }

    private static func maximum(_ lhs: UsageTokenBreakdown, _ rhs: UsageTokenBreakdown) -> UsageTokenBreakdown {
        .init(input: max(lhs.input, rhs.input), cachedInput: max(lhs.cachedInput, rhs.cachedInput), cacheCreation: max(lhs.cacheCreation, rhs.cacheCreation), cacheCreation1h: max(lhs.cacheCreation1h, rhs.cacheCreation1h), output: max(lhs.output, rhs.output), reasoning: max(lhs.reasoning, rhs.reasoning))
    }

    private static func tokenBreakdown(_ usage: [String: Any]) -> UsageTokenBreakdown {
        .init(input: int(usage["input_tokens"]), cachedInput: int(usage["cached_input_tokens"]), cacheCreation: int(usage["cache_creation_input_tokens"]), output: int(usage["output_tokens"]), reasoning: int(usage["reasoning_output_tokens"]))
    }

    private static func messageText(_ dictionary: [String: Any]) -> String? {
        if let message = dictionary["message"] as? String { return message }
        if let content = dictionary["content"] as? String { return content }
        if let message = dictionary["message"] as? [String: Any] { return messageText(message) }
        if let content = dictionary["content"] as? [Any] {
            for item in content {
                if let text = (item as? [String: Any]).flatMap({ string($0["text"]) ?? string($0["content"]) }) { return text }
            }
        }
        return nil
    }

    private static func isSyntheticUserText(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("Base directory for this skill:") || text.hasPrefix("<system-reminder>") || text.hasPrefix("Caveat: The messages below were generated by") || text.hasPrefix("<task-notification>")
    }

    private static func parentSessionID(fromSubagentPath path: String) -> String? {
        let pattern = #"[\\/]([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[\\/]subagents[\\/](?:[^\\/]+[\\/])*agent-[^\\/]+\.jsonl$"#
        guard let range = path.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = String(path[range])
        return match.split(whereSeparator: { $0 == "/" || $0 == "\\" }).first.map(String.init)
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    private static func string(_ value: Any?) -> String? { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    private static func modelName(in dictionary: [String: Any]?) -> String? {
        guard let dictionary else { return nil }
        return (dictionary["model"] as? String) ?? (dictionary["model_name"] as? String) ?? (dictionary["modelName"] as? String)
    }
    private static func sessionIdentifier(in dictionary: [String: Any]?) -> String? {
        guard let dictionary else { return nil }
        return (dictionary["conversation_id"] as? String) ?? (dictionary["session_id"] as? String) ?? (dictionary["sessionId"] as? String)
    }
    private static func date(_ value: Any?) -> Date? { guard let string = value as? String else { return nil }; return ISO8601DateFormatter().date(from: string) }
}
