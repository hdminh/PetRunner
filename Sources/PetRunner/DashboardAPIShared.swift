import AppKit
import Foundation
import PetRunnerCore

@MainActor
enum DashboardAPIShared {
    static func previewLimit(for query: [String: String]) -> Int {
        // Provider-scoped chart series need the full filtered window. The all-provider
        // overview only uses aggregates/buckets, so a smaller preview is fine.
        if let provider = query["provider"], provider != "all", !provider.isEmpty {
            return 20_000
        }
        return 2_000
    }

    static func filteredUsageRecords(_ records: [AgentUsageRecord], query: [String: String]) -> [AgentUsageRecord] {
        let start = startDate(for: query["range"] ?? "30d")
        return records.filter { record in
            if let start, record.occurredAt < start { return false }
            if let provider = query["provider"], provider != "all", record.provider.rawValue != provider { return false }
            if let model = query["model"], !model.isEmpty,
               !(record.model ?? "").localizedCaseInsensitiveContains(model) { return false }
            return true
        }
    }

    static func startDate(for range: String?) -> Date? {
        let calendar = Calendar.current
        switch range ?? "30d" {
        case "today", "1d": return calendar.startOfDay(for: .now)
        case "7d":
            let start = calendar.startOfDay(for: .now)
            return calendar.date(byAdding: .day, value: -6, to: start)
        case "30d":
            let start = calendar.startOfDay(for: .now)
            return calendar.date(byAdding: .day, value: -29, to: start)
        case "month", "mtd": return calendar.date(from: calendar.dateComponents([.year, .month], from: .now))
        case "90d":
            let start = calendar.startOfDay(for: .now)
            return calendar.date(byAdding: .day, value: -89, to: start)
        case "all": return nil
        default: return calendar.date(byAdding: .day, value: -30, to: .now)
        }
    }

    static func usageRecordJSON(_ record: AgentUsageRecord) -> [String: Any] {
        [
            "id": record.id, "provider": record.provider.rawValue, "sessionID": record.sessionID,
            "occurredAt": isoFormatter.string(from: record.occurredAt), "model": record.model ?? NSNull(),
            "tokens": [
                "input": record.tokens.input, "cachedInput": record.tokens.cachedInput,
                "cacheCreation": record.tokens.cacheCreation,
                "cacheCreation1h": record.tokens.cacheCreation1h,
                "output": record.tokens.output, "reasoning": record.tokens.reasoning, "total": record.totalTokens
            ],
            "cost": record.cost.usd ?? NSNull(),
            "provenance": record.cost.provenance.rawValue,
            "pricingVersion": record.cost.pricingVersion ?? NSNull(),
            "usageType": record.usageType?.rawValue ?? NSNull()
        ]
    }

    static func usageSessionJSON(_ session: UsageSessionSummary) -> [String: Any] {
        [
            "id": session.sessionID,
            "provider": session.provider.rawValue,
            "title": session.title,
            "project": session.project ?? NSNull(),
            "projectPath": session.projectPath ?? NSNull(),
            "startedAt": isoFormatter.string(from: session.startedAt),
            "updatedAt": isoFormatter.string(from: session.lastActivityAt),
            "durationSeconds": session.durationSeconds,
            "models": session.models,
            "primaryModel": session.primaryModel ?? NSNull(),
            "requestCount": session.requestCount,
            "tokens": tokenJSON(session.tokens, total: session.totalTokens),
            "knownCostUSD": session.knownCostUSD ?? NSNull(),
            "unpricedRecordCount": session.unpricedRecordCount,
            "provenance": session.provenance
        ]
    }

    static func usageProjectJSON(_ project: UsageProjectSummary) -> [String: Any] {
        [
            "id": project.projectKey,
            "provider": project.provider.rawValue,
            "name": project.name,
            "path": project.path ?? NSNull(),
            "sessionCount": project.sessionCount,
            "requestCount": project.requestCount,
            "tokens": tokenJSON(project.tokens, total: project.totalTokens),
            "knownCostUSD": project.knownCostUSD,
            "updatedAt": isoFormatter.string(from: project.lastActivityAt),
            "models": project.models
        ]
    }

    static func usageActivityJSON(_ stats: UsageActivityStats) -> [String: Any] {
        var object: [String: Any] = [
            "activeDays": stats.activeDays,
            "currentStreak": stats.currentStreak,
            "longestStreak": stats.longestStreak,
            "peakHour": stats.peakHour,
            "requestCount": stats.requestCount,
            "totalTokens": stats.totalTokens,
            "heatmap": stats.heatmap,
            "heatmapMax": stats.heatmapMax,
            "tokenHeatmap": stats.tokenHeatmap,
        ]
        if let comparison = stats.comparison {
            object["comparison"] = [
                "refKey": comparison.refKey,
                "label": comparison.label,
                "multiplier": comparison.multiplier,
            ]
        } else {
            object["comparison"] = NSNull()
        }
        return object
    }

    static func usageModelJSON(_ model: UsageModelSummary) -> [String: Any] {
        [
            "id": model.model,
            "provider": model.provider.rawValue,
            "model": model.model,
            "displayName": model.displayName,
            "requestCount": model.requestCount,
            "tokens": tokenJSON(model.tokens, total: model.totalTokens),
            "knownCostUSD": model.knownCostUSD,
            "cacheSavedUSD": model.cacheSavedUSD,
            "costShare": model.costShare,
            "tokenShare": model.tokenShare,
            "cacheHitRatio": model.cacheHitRatio,
            "pricingResolved": model.pricingResolved,
            "inputPerMillionUSD": model.inputPerMillionUSD ?? NSNull(),
            "outputPerMillionUSD": model.outputPerMillionUSD ?? NSNull(),
            "cacheReadPerMillionUSD": model.cacheReadPerMillionUSD ?? NSNull()
        ]
    }

    static func sessionTimelineRecordJSON(_ record: AgentUsageRecord) -> [String: Any] {
        [
            "occurredAt": isoFormatter.string(from: record.occurredAt),
            "model": record.model ?? NSNull(),
            "tokens": tokenJSON(record.tokens, total: record.totalTokens),
            "knownCostUSD": record.cost.usd ?? NSNull(),
            "provenance": record.cost.provenance.rawValue
        ]
    }

    static func tokenJSON(_ tokens: UsageTokenBreakdown, total: Int? = nil) -> [String: Any] {
        [
            "input": tokens.input,
            "cachedInput": tokens.cachedInput,
            "cacheCreation": tokens.cacheCreation,
            "cacheCreation1h": tokens.cacheCreation1h,
            "output": tokens.output,
            "reasoning": tokens.reasoning,
            "total": total ?? tokens.total
        ]
    }

    static func sessionJSON(_ summary: AgentSessionHistorySummary) -> [String: Any] {
        [
            "id": String(summary.id), "name": summary.sessionName?.value ?? "Unnamed session",
            "provider": summary.provider.rawValue, "model": summary.model?.value ?? NSNull(),
            "status": summary.status.rawValue, "activity": summary.activity?.value ?? summary.status.detailText,
            "cost": summary.estimatedCost.map { NSDecimalNumber(decimal: $0.usd).doubleValue } ?? NSNull(),
            "firstSeenAt": isoFormatter.string(from: summary.firstSeenAt),
            "updatedAt": isoFormatter.string(from: summary.updatedAt),
            "finishedAt": summary.finishedAt.map(isoFormatter.string) ?? NSNull()
        ]
    }

    static func autonomyJSON(enabled: Bool, configuration: AutonomyConfiguration) -> [String: Any] {
        [
            "enabled": enabled, "minimumWait": configuration.minimumWait,
            "maximumWait": configuration.maximumWait,
            "actions": configuration.enabledActions.map(\.rawValue).sorted()
        ]
    }

    static func budgetJSON(_ configuration: ProviderBudgetConfiguration) -> [String: Any] {
        ["dailyUSD": configuration.dailyUSD ?? NSNull(), "monthlyUSD": configuration.monthlyUSD ?? NSNull()]
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        if value is NSNull || value == nil { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    static func invalidJSON() -> DashboardHTTPResponse {
        .error(status: 400, code: "invalid_json", message: "Expected a valid JSON object.")
    }

    static func notFound() -> DashboardHTTPResponse {
        .error(status: 404, code: "not_found", message: "Not found.")
    }

    static func serverError(_ error: Error) -> DashboardHTTPResponse {
        .error(status: 500, code: "internal_error", message: error.localizedDescription)
    }

    static let isoFormatter = ISO8601DateFormatter()
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()}
