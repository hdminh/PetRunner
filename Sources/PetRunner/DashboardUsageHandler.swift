import Foundation
import PetRunnerCore

@MainActor
struct DashboardUsageHandler {
    let deps: DashboardAPIDependencies

    func refreshPricingCatalog(query: [String: String]) -> DashboardHTTPResponse {
        do {
            let result = try PricingCatalogStore.shared.refreshSync()
            if result.changed {
                // New rates change `BundledPricing.version` / parser revision, so
                // the next usage scan rebuilds Claude/Codex costs from tokens.
                // Keep this silent — refreshing prices must not prompt Keychain.
                deps.onRefreshUsage(false)
            }
            return pricingCatalogResponse(
                query: query,
                refreshed: true,
                refreshSource: result.source,
                refreshError: nil
            )
        } catch {
            return pricingCatalogResponse(
                query: query,
                refreshed: false,
                refreshSource: BundledPricing.catalogSource,
                refreshError: error.localizedDescription
            )
        }
    }

    func pricingCatalogResponse(
        query: [String: String],
        refreshed: Bool = false,
        refreshSource: String? = nil,
        refreshError: String? = nil
    ) -> DashboardHTTPResponse {
        let requestedProvider: UsageProvider?
        if let raw = query["provider"], !raw.isEmpty, raw != "all" {
            guard let provider = UsageProvider(rawValue: raw) else {
                return .error(status: 400, code: "invalid_provider", message: "Unknown pricing provider.")
            }
            requestedProvider = provider
        } else {
            requestedProvider = nil
        }
        let entries: [BundledPricing.CatalogEntry]
        if requestedProvider == .cursor {
            entries = []
        } else {
            entries = BundledPricing.catalog(provider: requestedProvider)
        }
        let providerNotes: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: UsageProvider.allCases.map { provider in
            let hasCatalog = provider != .cursor
            let note: Any = provider == .cursor
                ? "Cursor spend is provider-reported (chargedCents). PetRunner does not maintain a local rate catalog."
                : NSNull()
            return (provider.rawValue, [
                "id": provider.rawValue,
                "name": provider.displayName,
                "hasLocalCatalog": hasCatalog,
                "note": note
            ] as [String: Any])
        })
        var object: [String: Any] = [
            "source": BundledPricing.catalogSource,
            "version": BundledPricing.version,
            "label": BundledPricing.catalogLabel,
            "providers": providerNotes,
            "models": entries.map(pricingCatalogEntryJSON),
            "count": entries.count
        ]
        if refreshed {
            object["refreshed"] = true
            object["refreshSource"] = refreshSource ?? BundledPricing.catalogSource
        }
        if let refreshError {
            object["refreshError"] = refreshError
            object["refreshed"] = false
        }
        return .json(object: object)
    }

    func pricingCatalogEntryJSON(_ entry: BundledPricing.CatalogEntry) -> [String: Any] {
        [
            "id": entry.id,
            "displayName": entry.displayName,
            "provider": entry.provider.rawValue,
            "inputPerMillionUSD": entry.inputPerMillionUSD,
            "outputPerMillionUSD": entry.outputPerMillionUSD,
            "cacheReadPerMillionUSD": entry.cacheReadPerMillionUSD as Any? ?? NSNull(),
            "cacheWritePerMillionUSD": entry.cacheWritePerMillionUSD as Any? ?? NSNull(),
            "contextThreshold": entry.contextThreshold as Any? ?? NSNull(),
            "inputAboveThresholdPerMillionUSD": entry.inputAboveThresholdPerMillionUSD as Any? ?? NSNull(),
            "outputAboveThresholdPerMillionUSD": entry.outputAboveThresholdPerMillionUSD as Any? ?? NSNull(),
            "cacheReadAboveThresholdPerMillionUSD": entry.cacheReadAboveThresholdPerMillionUSD as Any? ?? NSNull(),
            "cacheWriteAboveThresholdPerMillionUSD": entry.cacheWriteAboveThresholdPerMillionUSD as Any? ?? NSNull()
        ]
    }

    func usageResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let snapshot = deps.usageState() else {
            return .error(status: 409, code: "usage_unavailable", message: "Usage is still being indexed.")
        }
        let records = DashboardAPIShared.filteredUsageRecords(snapshot.all.records, query: query)
        let aggregate = UsageAggregate(records: records)
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: records) { calendar.startOfDay(for: $0.occurredAt) }
            .map { date, values -> [String: Any] in
                let value = UsageAggregate(records: values)
                return ["date": DashboardAPIShared.dayFormatter.string(from: date), "tokens": value.totalTokens, "cost": value.knownCostUSD]
            }
            .sorted { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
        let providerSummaries = Dictionary(uniqueKeysWithValues: UsageProvider.allCases.map { provider in
            let providerRecords = records.filter { $0.provider == provider }
            let providerAggregate = UsageAggregate(records: providerRecords)
            let models = Dictionary(grouping: providerRecords) { $0.model ?? "Unknown model" }
                .map { model, values -> [String: Any] in
                    let modelAggregate = UsageAggregate(records: values)
                    return ["model": model, "tokens": modelAggregate.totalTokens, "cost": modelAggregate.knownCostUSD, "recordCount": values.count]
                }
                .sorted { ($0["tokens"] as? Int ?? 0) > ($1["tokens"] as? Int ?? 0) }
            return (provider.rawValue, [
                "tokens": providerAggregate.totalTokens,
                "cost": providerAggregate.knownCostUSD,
                "sessions": providerAggregate.sessionCount,
                "recordCount": providerRecords.count,
                "models": models
            ] as [String: Any])
        })
        let responseRecords = records.sorted { $0.occurredAt > $1.occurredAt }.prefix(DashboardAPIShared.previewLimit(for: query)).map(DashboardAPIShared.usageRecordJSON)
        return .json(object: [
            "totals": [
                "tokens": aggregate.totalTokens,
                "input": aggregate.tokens.input,
                "cachedInput": aggregate.tokens.cachedInput,
                "output": aggregate.tokens.output,
                "cost": aggregate.knownCostUSD,
                "sessions": aggregate.sessionCount,
                "recordCount": records.count,
            ],
            "providers": providerSummaries,
            "buckets": buckets,
            "records": responseRecords,
            "truncated": records.count > responseRecords.count
        ])
    }

    /// Sessions are aggregated from the usage ledger (ccgauge-style), not from
    /// the historical session metadata table as a list source.
    func usageSessionsResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let snapshot = deps.usageState() else {
            return .error(status: 409, code: "usage_unavailable", message: "Sessions are still being indexed.")
        }
        guard let filtered = analyticsRecords(from: snapshot, query: query) else {
            return .error(status: 400, code: "invalid_query", message: "Invalid analytics query.")
        }
        let sessions = UsageSessionAggregator.sessions(
            from: filtered.records,
            metadata: filtered.metadata
        )
        return .json(object: [
            "sessions": sessions.map(DashboardAPIShared.usageSessionJSON),
            "count": sessions.count
        ])
    }

    func usageSessionDetailResponse(path: String) -> DashboardHTTPResponse {
        guard let snapshot = deps.usageState() else {
            return .error(status: 409, code: "usage_unavailable", message: "Sessions are still being indexed.")
        }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 3, pieces[0] == "sessions",
              let provider = UsageProvider(rawValue: String(pieces[1]))
        else { return DashboardAPIShared.notFound() }
        let sessionID = String(pieces[2]).removingPercentEncoding ?? String(pieces[2])
        let records = snapshot.all.records.filter { $0.provider == provider && $0.sessionID == sessionID }
        guard !records.isEmpty else { return DashboardAPIShared.notFound() }
        let session = UsageSessionAggregator.sessions(
            from: records,
            metadata: snapshot.sessionMetadata.filter { $0.provider == provider && $0.sessionID == sessionID }
        ).first!
        var response = DashboardAPIShared.usageSessionJSON(session)
        response["records"] = records
            .sorted { $0.occurredAt < $1.occurredAt }
            .map(DashboardAPIShared.sessionTimelineRecordJSON)
        return .json(object: response)
    }

    func usageProjectsResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let snapshot = deps.usageState() else {
            return .error(status: 409, code: "usage_unavailable", message: "Projects are still being indexed.")
        }
        guard let filtered = analyticsRecords(from: snapshot, query: query) else {
            return .error(status: 400, code: "invalid_query", message: "Invalid analytics query.")
        }
        let projects = UsageSessionAggregator.projects(
            from: filtered.records,
            metadata: filtered.metadata
        )
        return .json(object: [
            "projects": projects.map(DashboardAPIShared.usageProjectJSON),
            "count": projects.count
        ])
    }

    func usageModelsResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let snapshot = deps.usageState() else {
            return .error(status: 409, code: "usage_unavailable", message: "Models are still being indexed.")
        }
        guard let filtered = analyticsRecords(from: snapshot, query: query) else {
            return .error(status: 400, code: "invalid_query", message: "Invalid analytics query.")
        }
        let models = UsageSessionAggregator.models(from: filtered.records)
        return .json(object: [
            "models": models.map(DashboardAPIShared.usageModelJSON),
            "count": models.count
        ])
    }

    /// Lifetime Activity KPIs + week×hour heatmap (ccgauge-style).
    /// Defaults to the full ledger (`range=all`) so streaks/active days stay meaningful.
    func usageActivityResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let snapshot = deps.usageState() else {
            return .error(status: 409, code: "usage_unavailable", message: "Activity is still being indexed.")
        }
        var activityQuery = query
        if activityQuery["range"] == nil {
            activityQuery["range"] = "all"
        }
        guard let filtered = analyticsRecords(from: snapshot, query: activityQuery) else {
            return .error(status: 400, code: "invalid_query", message: "Invalid activity query.")
        }
        let stats = UsageActivityAggregator.stats(from: filtered.records)
        return .json(object: DashboardAPIShared.usageActivityJSON(stats))
    }

    func analyticsRecords(
        from snapshot: UsageSnapshot,
        query: [String: String]
    ) -> (records: [AgentUsageRecord], metadata: [HistoricalUsageSession])? {
        let requestedProvider: UsageProvider?
        if let rawProvider = query["provider"], rawProvider != "all" {
            guard let provider = UsageProvider(rawValue: rawProvider) else { return nil }
            requestedProvider = provider
        } else {
            requestedProvider = nil
        }
        let rangeStart = DashboardAPIShared.startDate(for: query["range"] ?? "all")
        var records = snapshot.all.records
        var metadata = snapshot.sessionMetadata
        if let requestedProvider {
            records = records.filter { $0.provider == requestedProvider }
            metadata = metadata.filter { $0.provider == requestedProvider }
        }
        if let rangeStart {
            records = records.filter { $0.occurredAt >= rangeStart }
        }
        if let model = query["model"], !model.isEmpty {
            records = records.filter { ($0.model ?? "").localizedCaseInsensitiveContains(model) }
        }
        return (records, metadata)
    }
}
