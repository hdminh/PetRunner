import Foundation
import PetRunnerCore

@MainActor
struct DashboardMonitorHandler {
    let deps: DashboardAPIDependencies

    func liveSessionsResponse(query: [String: String]) -> DashboardHTTPResponse {
        guard let store = deps.historyStore() else {
            return .error(status: 409, code: "history_unavailable", message: deps.historyError() ?? "Session history is unavailable.")
        }
        let historyQuery = AgentSessionHistoryQuery(
            provider: query["provider"].flatMap(AgentProvider.init(rawValue:)),
            model: query["model"].flatMap(AgentSessionModel.sanitized),
            searchText: query["q"],
            startDate: DashboardAPIShared.startDate(for: query["range"])
        )
        do {
            let summaries = try store.summaries(matching: historyQuery)
            return .json(object: ["sessions": summaries.map(DashboardAPIShared.sessionJSON)])
        } catch {
            return DashboardAPIShared.serverError(error)
        }
    }

    func liveSessionDetailResponse(path: String) -> DashboardHTTPResponse {
        guard let id = Int64(path.dropFirst("/live-sessions/".count)), let store = deps.historyStore() else { return DashboardAPIShared.notFound() }
        do {
            guard let summary = try store.summaries().first(where: { $0.id == id }) else { return DashboardAPIShared.notFound() }
            var result = DashboardAPIShared.sessionJSON(summary)
            result["timeline"] = try store.timeline(for: id).map { entry in
                [
                    "occurredAt": DashboardAPIShared.isoFormatter.string(from: entry.occurredAt),
                    "status": entry.status.rawValue,
                    "model": entry.model?.value ?? NSNull(),
                    "activity": entry.activity?.value ?? entry.status.detailText,
                    "cost": entry.estimatedCost.map { NSDecimalNumber(decimal: $0.usd).doubleValue } ?? NSNull()
                ] as [String: Any]
            }
            return .json(object: result)
        } catch {
            return DashboardAPIShared.serverError(error)
        }
    }
    func monitorJSON() -> [String: Any] {
        let state = deps.monitorState()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let detections = Dictionary(uniqueKeysWithValues: state.detections.map { ($0.provider, $0.isDetected) })
        let appearance = state.appearance
        return [
            "enabled": state.enabled,
            "provider": state.provider?.rawValue as Any? ?? NSNull(),
            "visibleFields": appearance.visibleFields.map(\.rawValue),
            "appearance": [
                "scale": appearance.scale.rawValue,
                "fontSize": appearance.fontSize.rawValue,
                "useProviderHeaderTint": appearance.useProviderHeaderTint,
                "visibleFields": appearance.visibleFields.map(\.rawValue)
            ],
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

    func updateMonitor(body: Data) -> DashboardHTTPResponse {
        guard let object = DashboardAPIShared.jsonObject(body) else { return DashboardAPIShared.invalidJSON() }

        var appearance = deps.monitorState().appearance
        var appearanceChanged = false
        if let scaleRaw = object["scale"] as? String, let scale = MonitorBubbleScale(rawValue: scaleRaw) {
            appearance.scale = scale
            appearanceChanged = true
        }
        if let fontRaw = object["fontSize"] as? String, let fontSize = MonitorBubbleFontSize(rawValue: fontRaw) {
            appearance.fontSize = fontSize
            appearanceChanged = true
        }
        if let tint = object["useProviderHeaderTint"] as? Bool {
            appearance.useProviderHeaderTint = tint
            appearanceChanged = true
        }
        if let fields = object["visibleFields"] as? [String] {
            let parsed = fields.compactMap(MonitorBubbleField.init(rawValue:))
            if !parsed.isEmpty {
                appearance.visibleFields = parsed
                appearanceChanged = true
            }
        }
        if let appearanceObject = object["appearance"] as? [String: Any] {
            if let scaleRaw = appearanceObject["scale"] as? String, let scale = MonitorBubbleScale(rawValue: scaleRaw) {
                appearance.scale = scale
                appearanceChanged = true
            }
            if let fontRaw = appearanceObject["fontSize"] as? String, let fontSize = MonitorBubbleFontSize(rawValue: fontRaw) {
                appearance.fontSize = fontSize
                appearanceChanged = true
            }
            if let tint = appearanceObject["useProviderHeaderTint"] as? Bool {
                appearance.useProviderHeaderTint = tint
                appearanceChanged = true
            }
            if let fields = appearanceObject["visibleFields"] as? [String] {
                let parsed = fields.compactMap(MonitorBubbleField.init(rawValue:))
                if !parsed.isEmpty {
                    appearance.visibleFields = parsed
                    appearanceChanged = true
                }
            }
        }
        if appearanceChanged {
            deps.onSetMonitorAppearance(appearance)
        }

        guard object["enabled"] != nil else {
            return .json(object: monitorJSON().merging(["ok": true]) { _, new in new })
        }
        guard let enabled = object["enabled"] as? Bool else {
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
        if enabled, provider == nil, deps.monitorState().provider == nil {
            return .error(status: 400, code: "provider_required", message: "Choose a provider before enabling Agent Monitor.")
        }
        do {
            try deps.onSetMonitor(enabled, enabled ? (provider ?? deps.monitorState().provider) : nil)
            return .json(object: monitorJSON().merging(["ok": true]) { _, new in new })
        } catch {
            return .error(
                status: 500,
                code: "monitor_update_failed",
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}
