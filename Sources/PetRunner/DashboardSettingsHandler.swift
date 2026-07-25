import Foundation
import PetRunnerCore

@MainActor
struct DashboardSettingsHandler {
    let deps: DashboardAPIDependencies

    func stateJSON() -> [String: Any] {
        let snapshot = deps.usageState()
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
            let configuration = deps.budgetConfigurations()[provider] ?? .init()
            return (provider.rawValue, DashboardAPIShared.budgetJSON(configuration))
        })
        let pets = deps.petState()
        return [
            "apiVersion": 2,
            "platform": "macos",
            "capabilities": [
                "usage": true,
                "sessions": snapshot != nil,
                "historicalSessions": snapshot != nil,
                "liveSessions": deps.historyStore() != nil,
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
            "pets": pets.pets.map { DashboardPetsHandler(deps: deps).petJSON($0) },
            "failures": pets.failures.map { ["id": $0.id, "message": $0.message] },
            "pet": [
                "selectedID": pets.selectedPetID as Any? ?? NSNull(),
                "width": pets.width,
                "autonomy": DashboardAPIShared.autonomyJSON(enabled: pets.autonomyEnabled, configuration: pets.autonomyConfiguration)
            ],
            "monitor": DashboardMonitorHandler(deps: deps).monitorJSON(),
            "settings": [
                "budgets": budgets,
                "showStatusItem": deps.showsStatusItem(),
                "petHidden": deps.petHidden(),
                "quotaBarVisible": deps.quotaBarVisible(),
                "quotaBarMode": deps.quotaBarMode().rawValue,
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

    func providerJSON() -> [[String: Any]] {
        let snapshot = deps.usageState()
        return UsageProvider.allCases.map { provider in
            let enabled = deps.isProviderEnabled(provider)
            let today = UsageAggregate(records: snapshot?.today.records.filter { $0.provider == provider } ?? [])
            let month = UsageAggregate(records: snapshot?.month.records.filter { $0.provider == provider } ?? [])
            let configuration = deps.budgetConfigurations()[provider] ?? .init()
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
            var payload: [String: Any] = [
                "id": provider.rawValue,
                "name": provider.displayName,
                "enabled": enabled,
                "todayTokens": today.totalTokens,
                "todayCost": today.knownCostUSD,
                "monthCost": month.knownCostUSD,
                "sessionCount": today.sessionCount,
                "budget": DashboardAPIShared.budgetJSON(configuration),
                "costLabel": provider == .cursor ? "Cursor-metered (charged)" : "Local estimate",
                "connected": connected,
                "account": (account.email ?? account.displayName) as Any? ?? NSNull(),
                "email": account.email as Any? ?? NSNull(),
                "plan": account.plan as Any? ?? NSNull(),
                "organization": account.organization as Any? ?? NSNull(),
                "source": account.source,
                "status": enabled ? account.status : "Disabled",
                "updatedAt": account.updatedAt.map(DashboardAPIShared.isoFormatter.string) as Any? ?? NSNull(),
                "usageURL": links.usageURL.absoluteString,
                "statusURL": links.statusURL.absoluteString
            ]
            if let quota = deps.quotaState()[provider] {
                payload["quota"] = quotaJSON(quota)
            }
            return payload
        }
    }

    func quotaJSON(_ quota: ProviderQuotaSnapshot) -> [String: Any] {
        func windowJSON(_ window: RateWindow?) -> Any {
            guard let window else { return NSNull() }
            return [
                "usedPercent": window.usedPercent,
                "remainingPercent": window.remainingPercent,
                "windowMinutes": window.windowMinutes as Any? ?? NSNull(),
                "resetsAt": window.resetsAt.map(DashboardAPIShared.isoFormatter.string) as Any? ?? NSNull(),
                "label": window.label as Any? ?? NSNull()
            ]
        }
        var payload: [String: Any] = [
            "primary": windowJSON(quota.primary),
            "secondary": windowJSON(quota.secondary),
            "tertiary": windowJSON(quota.tertiary),
            "source": quota.source,
            "updatedAt": DashboardAPIShared.isoFormatter.string(from: quota.updatedAt),
            "message": quota.message as Any? ?? NSNull()
        ]
        if let monthly = quota.monthlySpend {
            payload["monthlySpend"] = [
                "usedUSD": monthly.usedUSD,
                "limitUSD": monthly.limitUSD as Any? ?? NSNull(),
                "resetsAt": monthly.resetsAt.map(DashboardAPIShared.isoFormatter.string) as Any? ?? NSNull()
            ]
        } else {
            payload["monthlySpend"] = NSNull()
        }
        return payload
    }
    func updateBudgets(body: Data) -> DashboardHTTPResponse {
        guard let object = DashboardAPIShared.jsonObject(body) else { return DashboardAPIShared.invalidJSON() }
        let rawBudgets = object["budgets"] as? [String: Any] ?? object
        var configurations = deps.budgetConfigurations()
        for (key, rawValue) in rawBudgets {
            guard let provider = UsageProvider(rawValue: key), let values = rawValue as? [String: Any] else { continue }
            configurations[provider] = ProviderBudgetConfiguration(
                dailyUSD: DashboardAPIShared.number(values["dailyUSD"]),
                monthlyUSD: DashboardAPIShared.number(values["monthlyUSD"])
            )
        }
        deps.onSetBudgetConfigurations(configurations)
        return .json(object: ["ok": true])
    }

    func updateSettings(body: Data) -> DashboardHTTPResponse {
        guard let object = DashboardAPIShared.jsonObject(body) else { return DashboardAPIShared.invalidJSON() }
        if let showStatusItem = object["showStatusItem"] as? Bool {
            deps.onSetStatusItemVisible(showStatusItem)
        }
        if let hidden = object["petHidden"] as? Bool {
            deps.onSetPetHidden(hidden)
        }
        if let visible = object["quotaBarVisible"] as? Bool {
            deps.onSetQuotaBarVisible(visible)
        }
        if let rawMode = object["quotaBarMode"] as? String, let mode = QuotaBarMode(rawValue: rawMode) {
            deps.onSetQuotaBarMode(mode)
        }
        if let petsDirectory = object["petsDirectory"] as? String {
            do {
                try deps.onSetPetsDirectory(petsDirectory)
            } catch {
                return .error(
                    status: 400,
                    code: "invalid_pets_directory",
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
        if let rawBudgets = object["budgets"] as? [String: Any] {
            var configurations = deps.budgetConfigurations()
            for (key, rawValue) in rawBudgets {
                guard let provider = UsageProvider(rawValue: key), let values = rawValue as? [String: Any] else { continue }
                configurations[provider] = ProviderBudgetConfiguration(
                    dailyUSD: DashboardAPIShared.number(values["dailyUSD"]),
                    monthlyUSD: DashboardAPIShared.number(values["monthlyUSD"])
                )
            }
            deps.onSetBudgetConfigurations(configurations)
        }
        return .json(object: ["ok": true])
    }
    func updateProvider(path: String, body: Data) -> DashboardHTTPResponse {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0] == "providers",
              let provider = UsageProvider(rawValue: String(pieces[1]))
        else { return DashboardAPIShared.notFound() }
        guard let object = DashboardAPIShared.jsonObject(body), let enabled = object["enabled"] as? Bool else {
            return .error(status: 400, code: "invalid_provider", message: "Expected { \"enabled\": true|false }.")
        }
        deps.onSetProviderEnabled(provider, enabled)
        return .json(object: ["ok": true, "id": provider.rawValue, "enabled": enabled])
    }
}
