import AppKit
import Foundation
import PetRunnerCore

struct DashboardPetState {
    let pets: [PetDescriptor]
    let failures: [PetFailure]
    let selectedPetID: String?
    let width: CGFloat
    let autonomyEnabled: Bool
    let autonomyConfiguration: AutonomyConfiguration
    let petsDirectory: String
    let petsDirectorySource: String
    let petsDirectoryEditable: Bool
}

struct DashboardMonitorState {
    let enabled: Bool
    let provider: AgentProvider?
    let detections: [ProviderDetection]
}

@MainActor
final class DashboardAPIController {
    private let historyStore: () -> AgentSessionHistoryStore?
    private let historyError: () -> String?
    private let usageState: () -> UsageSnapshot?
    private let petState: () -> DashboardPetState
    private let showsStatusItem: () -> Bool
    private let budgetConfigurations: () -> [UsageProvider: ProviderBudgetConfiguration]
    private let isProviderEnabled: (UsageProvider) -> Bool
    private let onSelectPet: (String) -> Void
    private let onSetWidth: (CGFloat) -> Void
    private let onResetPosition: () -> Void
    private let onRemovePet: (String) throws -> Void
    private let onSetAutonomy: (Bool, AutonomyConfiguration) -> Void
    private let onRefreshUsage: () -> Void
    private let onSetStatusItemVisible: (Bool) -> Void
    private let onImportPet: () -> Void
    private let onChoosePetsDirectory: () -> Void
    private let onSetPetsDirectory: (String) throws -> Void
    private let onRevealPetsDirectory: () -> Void
    private let onSetBudgetConfigurations: ([UsageProvider: ProviderBudgetConfiguration]) -> Void
    private let onSetProviderEnabled: (UsageProvider, Bool) -> Void
    private let monitorState: () -> DashboardMonitorState
    private let onSetMonitor: (Bool, AgentProvider?) throws -> Void
    private let onResetMonitor: () -> Void

    init(
        historyStore: @escaping () -> AgentSessionHistoryStore?,
        historyError: @escaping () -> String?,
        usageState: @escaping () -> UsageSnapshot?,
        petState: @escaping () -> DashboardPetState,
        showsStatusItem: @escaping () -> Bool,
        budgetConfigurations: @escaping () -> [UsageProvider: ProviderBudgetConfiguration],
        isProviderEnabled: @escaping (UsageProvider) -> Bool = { _ in true },
        onSelectPet: @escaping (String) -> Void,
        onSetWidth: @escaping (CGFloat) -> Void,
        onResetPosition: @escaping () -> Void,
        onRemovePet: @escaping (String) throws -> Void,
        onSetAutonomy: @escaping (Bool, AutonomyConfiguration) -> Void,
        onRefreshUsage: @escaping () -> Void,
        onSetStatusItemVisible: @escaping (Bool) -> Void,
        onImportPet: @escaping () -> Void,
        onChoosePetsDirectory: @escaping () -> Void,
        onSetPetsDirectory: @escaping (String) throws -> Void,
        onRevealPetsDirectory: @escaping () -> Void,
        onSetBudgetConfigurations: @escaping ([UsageProvider: ProviderBudgetConfiguration]) -> Void,
        onSetProviderEnabled: @escaping (UsageProvider, Bool) -> Void = { _, _ in },
        monitorState: @escaping () -> DashboardMonitorState = {
            DashboardMonitorState(
                enabled: false,
                provider: nil,
                detections: AgentProvider.allCases.map { ProviderDetection(provider: $0, isDetected: false) }
            )
        },
        onSetMonitor: @escaping (Bool, AgentProvider?) throws -> Void = { _, _ in },
        onResetMonitor: @escaping () -> Void = {}
    ) {
        self.historyStore = historyStore
        self.historyError = historyError
        self.usageState = usageState
        self.petState = petState
        self.showsStatusItem = showsStatusItem
        self.budgetConfigurations = budgetConfigurations
        self.isProviderEnabled = isProviderEnabled
        self.onSelectPet = onSelectPet
        self.onSetWidth = onSetWidth
        self.onResetPosition = onResetPosition
        self.onRemovePet = onRemovePet
        self.onSetAutonomy = onSetAutonomy
        self.onRefreshUsage = onRefreshUsage
        self.onSetStatusItemVisible = onSetStatusItemVisible
        self.onImportPet = onImportPet
        self.onChoosePetsDirectory = onChoosePetsDirectory
        self.onSetPetsDirectory = onSetPetsDirectory
        self.onRevealPetsDirectory = onRevealPetsDirectory
        self.onSetBudgetConfigurations = onSetBudgetConfigurations
        self.onSetProviderEnabled = onSetProviderEnabled
        self.monitorState = monitorState
        self.onSetMonitor = onSetMonitor
        self.onResetMonitor = onResetMonitor
    }

    func response(for request: DashboardHTTPRequest) -> DashboardHTTPResponse {
        guard let marker = request.path.range(of: "/api/v2") else { return notFound() }
        let route = String(request.path[marker.upperBound...])
        switch (request.method, route) {
        case ("GET", "/overview"), ("HEAD", "/overview"), ("GET", "/state"), ("HEAD", "/state"):
            return .json(object: stateJSON())
        case ("GET", "/providers"), ("HEAD", "/providers"):
            return .json(object: ["providers": providerJSON()])
        case ("GET", "/pricing"), ("HEAD", "/pricing"):
            return pricingCatalogResponse(query: request.queryItems)
        case ("POST", "/pricing/refresh"):
            // v1: bundled static catalog — revalidate by returning the same snapshot.
            // Structured so a future LiteLLM (or similar) fetch can replace the body.
            return pricingCatalogResponse(query: request.queryItems, refreshed: true)
        case ("GET", "/usage"), ("HEAD", "/usage"):
            return usageResponse(query: request.queryItems)
        case ("GET", "/sessions"), ("HEAD", "/sessions"):
            return usageSessionsResponse(query: request.queryItems)
        case ("GET", let path) where path.hasPrefix("/sessions/"):
            return usageSessionDetailResponse(path: path)
        case ("HEAD", let path) where path.hasPrefix("/sessions/"):
            return usageSessionDetailResponse(path: path)
        case ("GET", "/projects"), ("HEAD", "/projects"):
            return usageProjectsResponse(query: request.queryItems)
        case ("GET", "/models"), ("HEAD", "/models"):
            return usageModelsResponse(query: request.queryItems)
        case ("GET", "/activity"), ("HEAD", "/activity"):
            return usageActivityResponse(query: request.queryItems)
        case ("GET", "/live-sessions"), ("HEAD", "/live-sessions"):
            return liveSessionsResponse(query: request.queryItems)
        case ("GET", let path) where path.hasPrefix("/live-sessions/"):
            return liveSessionDetailResponse(path: path)
        case ("HEAD", let path) where path.hasPrefix("/live-sessions/"):
            return liveSessionDetailResponse(path: path)
        case ("GET", let path) where path.hasPrefix("/pets/") && path.hasSuffix("/preview"):
            return previewResponse(path: path, query: request.queryItems)
        case ("HEAD", let path) where path.hasPrefix("/pets/") && path.hasSuffix("/preview"):
            return previewResponse(path: path, query: request.queryItems)
        case ("GET", let path) where path.hasPrefix("/pets/") && path.hasSuffix("/spritesheet"):
            return spritesheetResponse(path: path)
        case ("HEAD", let path) where path.hasPrefix("/pets/") && path.hasSuffix("/spritesheet"):
            return spritesheetResponse(path: path)
        case ("DELETE", let path) where path.hasPrefix("/pets/"):
            return removePet(path: path)
        case ("POST", "/refresh"), ("POST", "/usage/refresh"):
            onRefreshUsage()
            return .json(status: 202, object: ["ok": true])
        case ("PUT", "/pet"):
            return updatePet(body: request.body)
        case ("PUT", "/autonomy"):
            return updateAutonomy(body: request.body)
        case ("POST", "/pet/reset-position"):
            onResetPosition()
            return .json(object: ["ok": true])
        case ("POST", "/pet/import"):
            onImportPet()
            return .json(object: ["ok": true, "imported": true])
        case ("POST", "/pets/choose-directory"):
            onChoosePetsDirectory()
            return .json(object: ["ok": true])
        case ("POST", "/pets/reveal-directory"):
            onRevealPetsDirectory()
            return .json(object: ["ok": true])
        case ("PUT", "/settings"):
            return updateSettings(body: request.body)
        case ("PUT", "/budgets"):
            return updateBudgets(body: request.body)
        case ("PUT", let path) where path.hasPrefix("/providers/"):
            return updateProvider(path: path, body: request.body)
        case ("GET", "/monitor"), ("HEAD", "/monitor"):
            return .json(object: monitorJSON())
        case ("PUT", "/monitor"):
            return updateMonitor(body: request.body)
        case ("POST", "/monitor/reset"):
            onResetMonitor()
            return .json(object: ["ok": true])
        default:
            return notFound()
        }
    }

    private func stateJSON() -> [String: Any] {
        let snapshot = usageState()
        let today = snapshot?.today
        let topModel = today?.records.compactMap(\.model).reduce(into: [String: Int]()) { counts, model in
            counts[model, default: 0] += 1
        }.max(by: { $0.value < $1.value })?.key
        let inputTotal = today?.records.reduce(0) { total, record in
            total + (record.provider == .codex ? record.tokens.input : record.tokens.input + record.tokens.cachedInput + record.tokens.cacheCreation)
        } ?? 0
        let cachedInput = today?.records.reduce(0) { $0 + $1.tokens.cachedInput } ?? 0
        let cacheRatio = inputTotal == 0 ? 0 : Double(cachedInput) / Double(inputTotal)
        let budgets = Dictionary(uniqueKeysWithValues: UsageProvider.allCases.map { provider in
            let configuration = budgetConfigurations()[provider] ?? .init()
            return (provider.rawValue, budgetJSON(configuration))
        })
        let pets = petState()
        return [
            "apiVersion": 2,
            "platform": "macos",
            "capabilities": [
                "usage": true,
                "sessions": snapshot != nil,
                "historicalSessions": snapshot != nil,
                "liveSessions": historyStore() != nil,
                "cursorConnection": true,
                "petImport": true,
                "petRemove": true,
                "statusItem": true,
                "petPreview": true,
                "petsDirectory": true,
                "petsDirectoryBrowse": pets.petsDirectoryEditable,
                "agentMonitor": true
            ],
            "kpis": [
                "todayTokens": today?.totalTokens ?? 0,
                "todayCost": today?.knownCostUSD ?? 0,
                "cacheRatio": cacheRatio,
                "topModel": topModel ?? "No data",
                "sessionCount": today?.sessionCount ?? 0,
                "monthCost": snapshot?.month.knownCostUSD ?? 0
            ],
            "providers": providerJSON(),
            "pets": pets.pets.map(petJSON),
            "failures": pets.failures.map { ["id": $0.id, "message": $0.message] },
            "pet": [
                "selectedID": pets.selectedPetID as Any? ?? NSNull(),
                "width": pets.width,
                "autonomy": autonomyJSON(enabled: pets.autonomyEnabled, configuration: pets.autonomyConfiguration)
            ],
            "monitor": monitorJSON(),
            "settings": [
                "budgets": budgets,
                "showStatusItem": showsStatusItem(),
                "petsDirectory": pets.petsDirectory,
                "petsDirectorySource": pets.petsDirectorySource,
                "petsDirectoryEditable": pets.petsDirectoryEditable
            ],
            "cursor": [
                "connected": snapshot?.cursorStatus == "connected",
                "status": snapshot?.cursorStatus ?? "notConnected",
                "message": snapshot?.cursorMessage ?? NSNull()
            ]
        ]
    }

    private func pricingCatalogResponse(query: [String: String], refreshed: Bool = false) -> DashboardHTTPResponse {
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
            "source": "bundled",
            "version": BundledPricing.version,
            "label": "Bundled catalog · version \(BundledPricing.version)",
            "providers": providerNotes,
            "models": entries.map(pricingCatalogEntryJSON),
            "count": entries.count
        ]
        if refreshed {
            object["refreshed"] = true
            object["refreshSource"] = "bundled"
        }
        return .json(object: object)
    }

    private func pricingCatalogEntryJSON(_ entry: BundledPricing.CatalogEntry) -> [String: Any] {
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

    private func providerJSON() -> [[String: Any]] {
        let snapshot = usageState()
        return UsageProvider.allCases.map { provider in
            let enabled = isProviderEnabled(provider)
            let today = UsageAggregate(records: snapshot?.today.records.filter { $0.provider == provider } ?? [])
            let month = UsageAggregate(records: snapshot?.month.records.filter { $0.provider == provider } ?? [])
            let configuration = budgetConfigurations()[provider] ?? .init()
            let links = provider.officialLinks
            let account = ProviderAccountReader.account(
                for: provider,
                cursorStatus: snapshot?.cursorStatus,
                cursorMessage: snapshot?.cursorMessage
            )
            let connected: Bool
            if !enabled {
                connected = false
            } else if provider == .cursor {
                connected = snapshot?.cursorStatus == "connected" || account.connected
            } else {
                connected = account.connected
            }
            return [
                "id": provider.rawValue,
                "name": provider.displayName,
                "enabled": enabled,
                "todayTokens": today.totalTokens,
                "todayCost": today.knownCostUSD,
                "monthCost": month.knownCostUSD,
                "sessionCount": today.sessionCount,
                "budget": budgetJSON(configuration),
                "costLabel": provider == .cursor ? "Cursor-metered (charged)" : "Local estimate",
                "connected": connected,
                "account": (account.email ?? account.displayName) as Any? ?? NSNull(),
                "email": account.email as Any? ?? NSNull(),
                "plan": account.plan as Any? ?? NSNull(),
                "organization": account.organization as Any? ?? NSNull(),
                "source": account.source,
                "status": enabled ? account.status : "Disabled",
                "updatedAt": account.updatedAt.map(Self.isoFormatter.string) as Any? ?? NSNull(),
                "usageURL": links.usageURL.absoluteString,
                "statusURL": links.statusURL.absoluteString
            ]
        }
    }

    private func usageResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let snapshot = usageState() else {
            return .error(status: 409, code: "usage_unavailable", message: "Usage is still being indexed.")
        }
        let records = filteredUsageRecords(snapshot.all.records, query: query)
        let aggregate = UsageAggregate(records: records)
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: records) { calendar.startOfDay(for: $0.occurredAt) }
            .map { date, values -> [String: Any] in
                let value = UsageAggregate(records: values)
                return ["date": Self.dayFormatter.string(from: date), "tokens": value.totalTokens, "cost": value.knownCostUSD]
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
        let responseRecords = records.sorted { $0.occurredAt > $1.occurredAt }.prefix(previewLimit(for: query)).map(usageRecordJSON)
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
    private func usageSessionsResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let snapshot = usageState() else {
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
            "sessions": sessions.map(usageSessionJSON),
            "count": sessions.count
        ])
    }

    private func usageSessionDetailResponse(path: String) -> DashboardHTTPResponse {
        guard let snapshot = usageState() else {
            return .error(status: 409, code: "usage_unavailable", message: "Sessions are still being indexed.")
        }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 3, pieces[0] == "sessions",
              let provider = UsageProvider(rawValue: String(pieces[1]))
        else { return notFound() }
        let sessionID = String(pieces[2]).removingPercentEncoding ?? String(pieces[2])
        let records = snapshot.all.records.filter { $0.provider == provider && $0.sessionID == sessionID }
        guard !records.isEmpty else { return notFound() }
        let session = UsageSessionAggregator.sessions(
            from: records,
            metadata: snapshot.sessionMetadata.filter { $0.provider == provider && $0.sessionID == sessionID }
        ).first!
        var response = usageSessionJSON(session)
        response["records"] = records
            .sorted { $0.occurredAt < $1.occurredAt }
            .map(sessionTimelineRecordJSON)
        return .json(object: response)
    }

    private func usageProjectsResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let snapshot = usageState() else {
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
            "projects": projects.map(usageProjectJSON),
            "count": projects.count
        ])
    }

    private func usageModelsResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let snapshot = usageState() else {
            return .error(status: 409, code: "usage_unavailable", message: "Models are still being indexed.")
        }
        guard let filtered = analyticsRecords(from: snapshot, query: query) else {
            return .error(status: 400, code: "invalid_query", message: "Invalid analytics query.")
        }
        let models = UsageSessionAggregator.models(from: filtered.records)
        return .json(object: [
            "models": models.map(usageModelJSON),
            "count": models.count
        ])
    }

    /// Lifetime Activity KPIs + week×hour heatmap (ccgauge-style).
    /// Defaults to the full ledger (`range=all`) so streaks/active days stay meaningful.
    private func usageActivityResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let snapshot = usageState() else {
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
        return .json(object: usageActivityJSON(stats))
    }

    private func analyticsRecords(
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
        let rangeStart = startDate(for: query["range"] ?? "all")
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

    private func liveSessionsResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let store = historyStore() else {
            return .error(status: 409, code: "history_unavailable", message: historyError() ?? "Session history is unavailable.")
        }
        let historyQuery = AgentSessionHistoryQuery(
            provider: query["provider"].flatMap(AgentProvider.init(rawValue:)),
            model: query["model"].flatMap(AgentSessionModel.sanitized),
            searchText: query["q"],
            startDate: startDate(for: query["range"])
        )
        do {
            let summaries = try store.summaries(matching: historyQuery)
            return .json(object: ["sessions": summaries.map(sessionJSON)])
        } catch {
            return serverError(error)
        }
    }

    private func liveSessionDetailResponse(path: String) -> DashboardHTTPResponse {
        guard let id = Int64(path.dropFirst("/live-sessions/".count)), let store = historyStore() else { return notFound() }
        do {
            guard let summary = try store.summaries().first(where: { $0.id == id }) else { return notFound() }
            var result = sessionJSON(summary)
            result["timeline"] = try store.timeline(for: id).map { entry in
                [
                    "occurredAt": Self.isoFormatter.string(from: entry.occurredAt),
                    "status": entry.status.rawValue,
                    "model": entry.model?.value ?? NSNull(),
                    "activity": entry.activity?.value ?? entry.status.detailText,
                    "cost": entry.estimatedCost.map { NSDecimalNumber(decimal: $0.usd).doubleValue } ?? NSNull()
                ] as [String: Any]
            }
            return .json(object: result)
        } catch {
            return serverError(error)
        }
    }

    private func previewResponse(path: String, query: [String: String]) -> DashboardHTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 3, pieces[0] == "pets", pieces[2] == "preview",
              let pet = petState().pets.first(where: { $0.id == String(pieces[1]) }),
              let atlas = try? SpriteAtlas(contentsOf: pet.spritesheetURL, version: pet.version)
        else { return notFound() }
        let maxRow = pet.version.rowCount - 1
        let address: AtlasAddress
        if pet.version == .v2, let lookIndex = query["look"].flatMap(Int.init), let look = LookDirection.atlasAddress(for: lookIndex) {
            address = look
        } else if let row = query["row"].flatMap(Int.init), (0...maxRow).contains(row) {
            let column = clampedFrame(query["frame"] ?? query["column"], maximum: 7)
            address = AtlasAddress(row: row, column: column)
        } else {
            let action = query["action"].flatMap(AnimationState.init(rawValue:)) ?? .idle
            let maxFrame = max(0, action.frameDurations.count - 1)
            let column = clampedFrame(query["frame"] ?? query["column"], maximum: maxFrame)
            address = AtlasAddress(row: action.row, column: column)
        }
        guard let image = atlas.frame(at: address), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return .error(status: 409, code: "preview_unavailable", message: "Pet preview is unavailable.")
        }
        return DashboardHTTPResponse(status: 200, headers: ["Content-Type": "image/png", "Cache-Control": "no-store"], body: data)
    }

    private func spritesheetResponse(path: String) -> DashboardHTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 3, pieces[0] == "pets", pieces[2] == "spritesheet",
              let pet = petState().pets.first(where: { $0.id == String(pieces[1]) }),
              let data = try? Data(contentsOf: pet.spritesheetURL)
        else { return notFound() }
        let contentType: String
        switch pet.spritesheetURL.pathExtension.lowercased() {
        case "png": contentType = "image/png"
        case "webp": contentType = "image/webp"
        default: contentType = "application/octet-stream"
        }
        return DashboardHTTPResponse(status: 200, headers: ["Content-Type": contentType, "Cache-Control": "no-store"], body: data)
    }

    private func updatePet(body: Data) -> DashboardHTTPResponse {
        guard let object = jsonObject(body) else { return invalidJSON() }
        if let id = object["id"] as? String {
            guard petState().pets.contains(where: { $0.id == id }) else {
                return .error(status: 400, code: "invalid_pet", message: "Unknown pet.")
            }
            onSelectPet(id)
        }
        if let width = number(object["width"]) {
            guard [80, 112, 160, 224].contains(where: { abs(Double($0) - width) < 0.5 }) else {
                return .error(status: 400, code: "invalid_width", message: "Unsupported pet width.")
            }
            onSetWidth(CGFloat(width))
        }
        return .json(object: ["ok": true])
    }

    private func updateAutonomy(body: Data) -> DashboardHTTPResponse {
        guard let object = jsonObject(body), let enabled = object["enabled"] as? Bool,
              let minimum = number(object["minimumWait"]), let maximum = number(object["maximumWait"]),
              let names = object["actions"] as? [String]
        else { return invalidJSON() }
        let actions = Set(names.compactMap(AutonomousActionKind.init(rawValue:)))
        guard actions.count == names.count,
              let configuration = AutonomyConfiguration(minimumWait: minimum, maximumWait: maximum, enabledActions: actions)
        else { return .error(status: 400, code: "invalid_autonomy", message: "Invalid autonomy configuration.") }
        onSetAutonomy(enabled, configuration)
        return .json(object: ["ok": true])
    }

    private func updateBudgets(body: Data) -> DashboardHTTPResponse {
        guard let object = jsonObject(body) else { return invalidJSON() }
        let rawBudgets = object["budgets"] as? [String: Any] ?? object
        var configurations = budgetConfigurations()
        for (key, rawValue) in rawBudgets {
            guard let provider = UsageProvider(rawValue: key), let values = rawValue as? [String: Any] else { continue }
            configurations[provider] = ProviderBudgetConfiguration(
                dailyUSD: number(values["dailyUSD"]),
                monthlyUSD: number(values["monthlyUSD"])
            )
        }
        onSetBudgetConfigurations(configurations)
        return .json(object: ["ok": true])
    }

    private func updateSettings(body: Data) -> DashboardHTTPResponse {
        guard let object = jsonObject(body) else { return invalidJSON() }
        if let showStatusItem = object["showStatusItem"] as? Bool {
            onSetStatusItemVisible(showStatusItem)
        }
        if let petsDirectory = object["petsDirectory"] as? String {
            do {
                try onSetPetsDirectory(petsDirectory)
            } catch {
                return .error(
                    status: 400,
                    code: "invalid_pets_directory",
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
        if let rawBudgets = object["budgets"] as? [String: Any] {
            var configurations = budgetConfigurations()
            for (key, rawValue) in rawBudgets {
                guard let provider = UsageProvider(rawValue: key), let values = rawValue as? [String: Any] else { continue }
                configurations[provider] = ProviderBudgetConfiguration(
                    dailyUSD: number(values["dailyUSD"]),
                    monthlyUSD: number(values["monthlyUSD"])
                )
            }
            onSetBudgetConfigurations(configurations)
        }
        return .json(object: ["ok": true])
    }

    private func removePet(path: String) -> DashboardHTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0] == "pets" else { return notFound() }
        let rawID = String(pieces[1])
        let id = rawID.removingPercentEncoding ?? rawID
        guard !id.isEmpty, !id.contains("/"), id != "." && id != ".." else {
            return .error(status: 400, code: "invalid_pet", message: "Invalid pet id.")
        }
        do {
            try onRemovePet(id)
            let selected = petState().selectedPetID
            return .json(object: [
                "ok": true,
                "removed": id,
                "selectedID": selected as Any? ?? NSNull()
            ])
        } catch let error as PetRemovalError {
            switch error {
            case .notFound:
                return .error(status: 404, code: "pet_not_found", message: error.localizedDescription)
            case .escapesPetsDirectory, .invalidPetID:
                return .error(status: 400, code: "invalid_pet_path", message: error.localizedDescription)
            }
        } catch {
            return .error(
                status: 500,
                code: "remove_failed",
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private func petJSON(_ pet: PetDescriptor) -> [String: Any] {
        var json: [String: Any] = [
            "id": pet.id,
            "name": pet.displayName,
            "description": pet.description as Any? ?? NSNull(),
            "version": pet.version.rawValue
        ]
        let extras = optionalManifestFields(at: pet.packageURL)
        if let author = extras.author { json["author"] = author }
        if let tags = extras.tags { json["tags"] = tags }
        if let packageVersion = extras.packageVersion { json["packageVersion"] = packageVersion }
        if let kind = extras.kind { json["kind"] = kind }
        return json
    }

    private func optionalManifestFields(at packageURL: URL) -> (author: String?, tags: [String]?, packageVersion: String?, kind: String?) {
        let manifestURL = packageURL.appendingPathComponent("pet.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil, nil, nil) }
        let author = nonemptyString(object["author"] ?? object["creator"] ?? object["by"])
        let packageVersion = nonemptyString(object["packageVersion"] ?? object["version"]).flatMap { value in
            Int(value) != nil ? nil : value
        }
        let kind = nonemptyString(object["kind"])
        let tags: [String]?
        if let rawTags = object["tags"] as? [String] {
            let cleaned = rawTags.compactMap(nonemptyString)
            tags = cleaned.isEmpty ? nil : cleaned
        } else {
            tags = nil
        }
        return (author, tags, packageVersion, kind)
    }

    private func nonemptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func clampedFrame(_ raw: String?, maximum: Int) -> Int {
        guard let value = raw.flatMap(Int.init) else { return 0 }
        return min(max(0, value), maximum)
    }

    private func updateProvider(path: String, body: Data) -> DashboardHTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0] == "providers",
              let provider = UsageProvider(rawValue: String(pieces[1]))
        else { return notFound() }
        guard let object = jsonObject(body), let enabled = object["enabled"] as? Bool else {
            return .error(status: 400, code: "invalid_provider", message: "Expected { \"enabled\": true|false }.")
        }
        onSetProviderEnabled(provider, enabled)
        return .json(object: ["ok": true, "id": provider.rawValue, "enabled": enabled])
    }

    private func monitorJSON() -> [String: Any] {
        let state = monitorState()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let detections = Dictionary(uniqueKeysWithValues: state.detections.map { ($0.provider, $0.isDetected) })
        return [
            "enabled": state.enabled,
            "provider": state.provider?.rawValue as Any? ?? NSNull(),
            "visibleFields": MonitorBubbleField.allCases.map(\.rawValue),
            "providers": AgentProvider.allCases.map { provider -> [String: Any] in
                let configuration = ProviderHookConfiguration(provider: provider)
                let color = provider.headerColor
                return [
                    "id": provider.rawValue,
                    "name": provider.displayLabel,
                    "detected": detections[provider] ?? false,
                    "hooksDirectory": configuration.hooksDirectoryURL(home: home).path,
                    "configPath": configuration.configURL(home: home).path,
                    "headerColor": [
                        "red": color.red,
                        "green": color.green,
                        "blue": color.blue
                    ]
                ]
            }
        ]
    }

    private func updateMonitor(body: Data) -> DashboardHTTPResponse {
        guard let object = jsonObject(body), let enabled = object["enabled"] as? Bool else {
            return .error(status: 400, code: "invalid_monitor", message: "Expected { \"enabled\": true|false, \"provider\"?: \"claude\"|\"codex\"|\"cursor\" }.")
        }
        let provider: AgentProvider?
        if let raw = object["provider"] as? String {
            guard let parsed = AgentProvider(rawValue: raw) else {
                return .error(status: 400, code: "invalid_provider", message: "Unknown monitor provider.")
            }
            provider = parsed
        } else {
            provider = nil
        }
        if enabled, provider == nil, monitorState().provider == nil {
            return .error(status: 400, code: "provider_required", message: "Choose a provider before enabling Agent Monitor.")
        }
        do {
            try onSetMonitor(enabled, enabled ? (provider ?? monitorState().provider) : nil)
            return .json(object: monitorJSON().merging(["ok": true]) { _, new in new })
        } catch {
            return .error(
                status: 500,
                code: "monitor_update_failed",
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private func previewLimit(for query: [String: String]) -> Int {
        // Provider-scoped chart series need the full filtered window. The all-provider
        // overview only uses aggregates/buckets, so a smaller preview is fine.
        if let provider = query["provider"], provider != "all", !provider.isEmpty {
            return 20_000
        }
        return 2_000
    }

    private func filteredUsageRecords(_ records: [AgentUsageRecord], query: [String: String]) -> [AgentUsageRecord] {
        let start = startDate(for: query["range"] ?? "30d")
        return records.filter { record in
            if let start, record.occurredAt < start { return false }
            if let provider = query["provider"], provider != "all", record.provider.rawValue != provider { return false }
            if let model = query["model"], !model.isEmpty,
               !(record.model ?? "").localizedCaseInsensitiveContains(model) { return false }
            return true
        }
    }

    private func startDate(for range: String?) -> Date? {
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

    private func usageRecordJSON(_ record: AgentUsageRecord) -> [String: Any] {
        [
            "id": record.id, "provider": record.provider.rawValue, "sessionID": record.sessionID,
            "occurredAt": Self.isoFormatter.string(from: record.occurredAt), "model": record.model ?? NSNull(),
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

    private func usageSessionJSON(_ session: UsageSessionSummary) -> [String: Any] {
        [
            "id": session.sessionID,
            "provider": session.provider.rawValue,
            "title": session.title,
            "project": session.project ?? NSNull(),
            "projectPath": session.projectPath ?? NSNull(),
            "startedAt": Self.isoFormatter.string(from: session.startedAt),
            "updatedAt": Self.isoFormatter.string(from: session.lastActivityAt),
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

    private func usageProjectJSON(_ project: UsageProjectSummary) -> [String: Any] {
        [
            "id": project.projectKey,
            "provider": project.provider.rawValue,
            "name": project.name,
            "path": project.path ?? NSNull(),
            "sessionCount": project.sessionCount,
            "requestCount": project.requestCount,
            "tokens": tokenJSON(project.tokens, total: project.totalTokens),
            "knownCostUSD": project.knownCostUSD,
            "updatedAt": Self.isoFormatter.string(from: project.lastActivityAt),
            "models": project.models
        ]
    }

    private func usageActivityJSON(_ stats: UsageActivityStats) -> [String: Any] {
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

    private func usageModelJSON(_ model: UsageModelSummary) -> [String: Any] {
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

    private func sessionTimelineRecordJSON(_ record: AgentUsageRecord) -> [String: Any] {
        [
            "occurredAt": Self.isoFormatter.string(from: record.occurredAt),
            "model": record.model ?? NSNull(),
            "tokens": tokenJSON(record.tokens, total: record.totalTokens),
            "knownCostUSD": record.cost.usd ?? NSNull(),
            "provenance": record.cost.provenance.rawValue
        ]
    }

    private func tokenJSON(_ tokens: UsageTokenBreakdown, total: Int? = nil) -> [String: Any] {
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

    private func sessionJSON(_ summary: AgentSessionHistorySummary) -> [String: Any] {
        [
            "id": String(summary.id), "name": summary.sessionName?.value ?? "Unnamed session",
            "provider": summary.provider.rawValue, "model": summary.model?.value ?? NSNull(),
            "status": summary.status.rawValue, "activity": summary.activity?.value ?? summary.status.detailText,
            "cost": summary.estimatedCost.map { NSDecimalNumber(decimal: $0.usd).doubleValue } ?? NSNull(),
            "firstSeenAt": Self.isoFormatter.string(from: summary.firstSeenAt),
            "updatedAt": Self.isoFormatter.string(from: summary.updatedAt),
            "finishedAt": summary.finishedAt.map(Self.isoFormatter.string) ?? NSNull()
        ]
    }

    private func autonomyJSON(enabled: Bool, configuration: AutonomyConfiguration) -> [String: Any] {
        [
            "enabled": enabled, "minimumWait": configuration.minimumWait,
            "maximumWait": configuration.maximumWait,
            "actions": configuration.enabledActions.map(\.rawValue).sorted()
        ]
    }

    private func budgetJSON(_ configuration: ProviderBudgetConfiguration) -> [String: Any] {
        ["dailyUSD": configuration.dailyUSD ?? NSNull(), "monthlyUSD": configuration.monthlyUSD ?? NSNull()]
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func number(_ value: Any?) -> Double? {
        if value is NSNull || value == nil { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    private func invalidJSON() -> DashboardHTTPResponse {
        .error(status: 400, code: "invalid_json", message: "Expected a valid JSON object.")
    }

    private func notFound() -> DashboardHTTPResponse {
        .error(status: 404, code: "not_found", message: "Not found.")
    }

    private func serverError(_ error: Error) -> DashboardHTTPResponse {
        .error(status: 500, code: "internal_error", message: error.localizedDescription)
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
