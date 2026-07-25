import Foundation

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
