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
    let appearance: MonitorBubbleAppearance
}

@MainActor
struct DashboardAPIDependencies {
    let historyStore: () -> AgentSessionHistoryStore?
    let historyError: () -> String?
    let usageState: () -> UsageSnapshot?
    let quotaState: () -> [UsageProvider: ProviderQuotaSnapshot]
    let petState: () -> DashboardPetState
    let showsStatusItem: () -> Bool
    let petHidden: () -> Bool
    let quotaBarVisible: () -> Bool
    let quotaBarMode: () -> QuotaBarMode
    let budgetConfigurations: () -> [UsageProvider: ProviderBudgetConfiguration]
    let isProviderEnabled: (UsageProvider) -> Bool
    let onSelectPet: (String) -> Void
    let onSetWidth: (CGFloat) -> Void
    let onResetPosition: () -> Void
    let onRemovePet: (String) throws -> Void
    let onSetAutonomy: (Bool, AutonomyConfiguration) -> Void
    let onRefreshUsage: (_ allowClaudeKeychainPrompt: Bool) -> Void
    let onSetStatusItemVisible: (Bool) -> Void
    let onSetPetHidden: (Bool) -> Void
    let onSetQuotaBarVisible: (Bool) -> Void
    let onSetQuotaBarMode: (QuotaBarMode) -> Void
    let onImportPet: () -> Void
    let onChoosePetsDirectory: () -> Void
    let onSetPetsDirectory: (String) throws -> Void
    let onRevealPetsDirectory: () -> Void
    let onSetBudgetConfigurations: ([UsageProvider: ProviderBudgetConfiguration]) -> Void
    let onSetProviderEnabled: (UsageProvider, Bool) -> Void
    let monitorState: () -> DashboardMonitorState
    let onSetMonitor: (Bool, AgentProvider?) throws -> Void
    let onResetMonitor: () -> Void
    let onSetMonitorAppearance: (MonitorBubbleAppearance) -> Void

    init(
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
        self.historyStore = historyStore
        self.historyError = historyError
        self.usageState = usageState
        self.quotaState = quotaState
        self.petState = petState
        self.showsStatusItem = showsStatusItem
        self.petHidden = petHidden
        self.quotaBarVisible = quotaBarVisible
        self.quotaBarMode = quotaBarMode
        self.budgetConfigurations = budgetConfigurations
        self.isProviderEnabled = isProviderEnabled
        self.onSelectPet = onSelectPet
        self.onSetWidth = onSetWidth
        self.onResetPosition = onResetPosition
        self.onRemovePet = onRemovePet
        self.onSetAutonomy = onSetAutonomy
        self.onRefreshUsage = onRefreshUsage
        self.onSetStatusItemVisible = onSetStatusItemVisible
        self.onSetPetHidden = onSetPetHidden
        self.onSetQuotaBarVisible = onSetQuotaBarVisible
        self.onSetQuotaBarMode = onSetQuotaBarMode
        self.onImportPet = onImportPet
        self.onChoosePetsDirectory = onChoosePetsDirectory
        self.onSetPetsDirectory = onSetPetsDirectory
        self.onRevealPetsDirectory = onRevealPetsDirectory
        self.onSetBudgetConfigurations = onSetBudgetConfigurations
        self.onSetProviderEnabled = onSetProviderEnabled
        self.monitorState = monitorState
        self.onSetMonitor = onSetMonitor
        self.onResetMonitor = onResetMonitor
        self.onSetMonitorAppearance = onSetMonitorAppearance
    }
}
