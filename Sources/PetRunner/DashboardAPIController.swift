import Foundation
import PetRunnerCore

@MainActor
final class DashboardAPIController {
    private let deps: DashboardAPIDependencies
    private let usage: DashboardUsageHandler
    private let pets: DashboardPetsHandler
    private let monitor: DashboardMonitorHandler
    private let settings: DashboardSettingsHandler

    init(deps: DashboardAPIDependencies) {
        self.deps = deps
        self.usage = DashboardUsageHandler(deps: deps)
        self.pets = DashboardPetsHandler(deps: deps)
        self.monitor = DashboardMonitorHandler(deps: deps)
        self.settings = DashboardSettingsHandler(deps: deps)
    }

    /// Compatibility initializer used by AppDelegate wiring and tests.
    convenience init(
        historyStore: @escaping () -> AgentSessionHistoryStore?,
        historyError: @escaping () -> String?,
        usageState: @escaping () -> UsageSnapshot?,
        quotaState: @escaping () -> [UsageProvider: ProviderQuotaSnapshot] = { [:] },
        petState: @escaping () -> DashboardPetState,
        showsStatusItem: @escaping () -> Bool,
        petHidden: @escaping () -> Bool = { false },
        quotaBarVisible: @escaping () -> Bool = { true },
        quotaBarMode: @escaping () -> QuotaBarMode = { .auto },
        budgetConfigurations: @escaping () -> [UsageProvider: ProviderBudgetConfiguration],
        isProviderEnabled: @escaping (UsageProvider) -> Bool = { _ in true },
        onSelectPet: @escaping (String) -> Void,
        onSetWidth: @escaping (CGFloat) -> Void,
        onResetPosition: @escaping () -> Void,
        onRemovePet: @escaping (String) throws -> Void,
        onSetAutonomy: @escaping (Bool, AutonomyConfiguration) -> Void,
        onRefreshUsage: @escaping (_ allowClaudeKeychainPrompt: Bool) -> Void,
        onSetStatusItemVisible: @escaping (Bool) -> Void,
        onSetPetHidden: @escaping (Bool) -> Void = { _ in },
        onSetQuotaBarVisible: @escaping (Bool) -> Void = { _ in },
        onSetQuotaBarMode: @escaping (QuotaBarMode) -> Void = { _ in },
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
                detections: AgentProvider.allCases.map { ProviderDetection(provider: $0, isDetected: false) },
                appearance: .default
            )
        },
        onSetMonitor: @escaping (Bool, AgentProvider?) throws -> Void = { _, _ in },
        onResetMonitor: @escaping () -> Void = {},
        onSetMonitorAppearance: @escaping (MonitorBubbleAppearance) -> Void = { _ in }
    ) {
        self.init(
            deps: DashboardAPIDependencies(
                historyStore: historyStore,
                historyError: historyError,
                usageState: usageState,
                quotaState: quotaState,
                petState: petState,
                showsStatusItem: showsStatusItem,
                petHidden: petHidden,
                quotaBarVisible: quotaBarVisible,
                quotaBarMode: quotaBarMode,
                budgetConfigurations: budgetConfigurations,
                isProviderEnabled: isProviderEnabled,
                onSelectPet: onSelectPet,
                onSetWidth: onSetWidth,
                onResetPosition: onResetPosition,
                onRemovePet: onRemovePet,
                onSetAutonomy: onSetAutonomy,
                onRefreshUsage: onRefreshUsage,
                onSetStatusItemVisible: onSetStatusItemVisible,
                onSetPetHidden: onSetPetHidden,
                onSetQuotaBarVisible: onSetQuotaBarVisible,
                onSetQuotaBarMode: onSetQuotaBarMode,
                onImportPet: onImportPet,
                onChoosePetsDirectory: onChoosePetsDirectory,
                onSetPetsDirectory: onSetPetsDirectory,
                onRevealPetsDirectory: onRevealPetsDirectory,
                onSetBudgetConfigurations: onSetBudgetConfigurations,
                onSetProviderEnabled: onSetProviderEnabled,
                monitorState: monitorState,
                onSetMonitor: onSetMonitor,
                onResetMonitor: onResetMonitor,
                onSetMonitorAppearance: onSetMonitorAppearance
            )
        )
    }

    func response(for request: DashboardHTTPRequest) -> DashboardHTTPResponse {
        guard let marker = request.path.range(of: "/api/v2") else { return DashboardAPIShared.notFound() }
        let route = String(request.path[marker.upperBound...])
        switch (request.method, route) {
        case ("GET", "/overview"), ("HEAD", "/overview"), ("GET", "/state"), ("HEAD", "/state"):
            return .json(object: settings.stateJSON())
        case ("GET", "/providers"), ("HEAD", "/providers"):
            return .json(object: ["providers": settings.providerJSON()])
        case ("GET", "/pricing"), ("HEAD", "/pricing"):
            return usage.pricingCatalogResponse(query: request.queryItems)
        case ("POST", "/pricing/refresh"):
            return usage.refreshPricingCatalog(query: request.queryItems)
        case ("GET", "/usage"), ("HEAD", "/usage"):
            return usage.usageResponse(query: request.queryItems)
        case ("GET", "/sessions"), ("HEAD", "/sessions"):
            return usage.usageSessionsResponse(query: request.queryItems)
        case ("GET", let path) where path.hasPrefix("/sessions/"):
            return usage.usageSessionDetailResponse(path: path)
        case ("HEAD", let path) where path.hasPrefix("/sessions/"):
            return usage.usageSessionDetailResponse(path: path)
        case ("GET", "/projects"), ("HEAD", "/projects"):
            return usage.usageProjectsResponse(query: request.queryItems)
        case ("GET", "/models"), ("HEAD", "/models"):
            return usage.usageModelsResponse(query: request.queryItems)
        case ("GET", "/activity"), ("HEAD", "/activity"):
            return usage.usageActivityResponse(query: request.queryItems)
        case ("GET", "/live-sessions"), ("HEAD", "/live-sessions"):
            return monitor.liveSessionsResponse(query: request.queryItems)
        case ("GET", let path) where path.hasPrefix("/live-sessions/"):
            return monitor.liveSessionDetailResponse(path: path)
        case ("HEAD", let path) where path.hasPrefix("/live-sessions/"):
            return monitor.liveSessionDetailResponse(path: path)
        case ("GET", let path) where path.hasPrefix("/pets/") && path.hasSuffix("/preview"):
            return pets.previewResponse(path: path, query: request.queryItems)
        case ("HEAD", let path) where path.hasPrefix("/pets/") && path.hasSuffix("/preview"):
            return pets.previewResponse(path: path, query: request.queryItems)
        case ("GET", let path) where path.hasPrefix("/pets/") && path.hasSuffix("/spritesheet"):
            return pets.spritesheetResponse(path: path)
        case ("HEAD", let path) where path.hasPrefix("/pets/") && path.hasSuffix("/spritesheet"):
            return pets.spritesheetResponse(path: path)
        case ("DELETE", let path) where path.hasPrefix("/pets/"):
            return pets.removePet(path: path)
        case ("POST", "/refresh"), ("POST", "/usage/refresh"):
            deps.onRefreshUsage(true)
            return .json(status: 202, object: ["ok": true])
        case ("PUT", "/pet"):
            return pets.updatePet(body: request.body)
        case ("PUT", "/autonomy"):
            return pets.updateAutonomy(body: request.body)
        case ("POST", "/pet/reset-position"):
            deps.onResetPosition()
            return .json(object: ["ok": true])
        case ("POST", "/pet/import"):
            deps.onImportPet()
            return .json(object: ["ok": true, "imported": true])
        case ("POST", "/pets/choose-directory"):
            deps.onChoosePetsDirectory()
            return .json(object: ["ok": true])
        case ("POST", "/pets/reveal-directory"):
            deps.onRevealPetsDirectory()
            return .json(object: ["ok": true])
        case ("PUT", "/settings"):
            return settings.updateSettings(body: request.body)
        case ("PUT", "/budgets"):
            return settings.updateBudgets(body: request.body)
        case ("PUT", let path) where path.hasPrefix("/providers/"):
            return settings.updateProvider(path: path, body: request.body)
        case ("GET", "/monitor"), ("HEAD", "/monitor"):
            return .json(object: monitor.monitorJSON())
        case ("PUT", "/monitor"):
            return monitor.updateMonitor(body: request.body)
        case ("POST", "/monitor/reset"):
            deps.onResetMonitor()
            return .json(object: ["ok": true])
        default:
            return DashboardAPIShared.notFound()
        }
    }
}
