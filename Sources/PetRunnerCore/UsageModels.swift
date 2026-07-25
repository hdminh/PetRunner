import Foundation

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

public struct UsageSourceHealth: Sendable, Equatable {
    public enum State: String, Sendable { case healthy, stale, unavailable }
    public let provider: UsageProvider
    public let state: State
    public let updatedAt: Date?
    public let detail: String?
}

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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
