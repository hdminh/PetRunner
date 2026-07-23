import CoreGraphics
import Foundation
import PetRunnerCore

struct PetRunnerPreferences {
    private enum Key {
        static let selectedPetID = "selectedPetID"
        static let petWidth = "petWidth"
        static let originX = "originX"
        static let originY = "originY"
        static let hasOrigin = "hasOrigin"
        static let monitorEnabled = "monitorEnabled"
        static let monitorProviders = "monitorProviders"
        static let monitorProvider = "monitorProvider"
        static let monitorBubbleCollapsed = "monitorBubbleCollapsed"
        static let autonomyEnabled = "autonomyEnabled"
        static let autonomyMinimumWait = "autonomyMinimumWait"
        static let autonomyMaximumWait = "autonomyMaximumWait"
        static let autonomyEnabledActions = "autonomyEnabledActions"
        static let showsStatusItem = "showsStatusItem"
        static let petsDirectory = "petsDirectory"
        static let budgets = "budgets"
        static let providerToggles = "providerToggles"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedPetID: String? {
        get { defaults.string(forKey: Key.selectedPetID) }
        nonmutating set { defaults.set(newValue, forKey: Key.selectedPetID) }
    }

    var petWidth: CGFloat {
        get {
            let stored = defaults.double(forKey: Key.petWidth)
            return stored == 0 ? 112 : min(max(stored, 80), 224)
        }
        nonmutating set { defaults.set(min(max(newValue, 80), 224), forKey: Key.petWidth) }
    }

    var origin: CGPoint? {
        get {
            guard defaults.bool(forKey: Key.hasOrigin) else { return nil }
            return CGPoint(
                x: defaults.double(forKey: Key.originX),
                y: defaults.double(forKey: Key.originY)
            )
        }
        nonmutating set {
            guard let newValue else {
                defaults.set(false, forKey: Key.hasOrigin)
                return
            }
            defaults.set(newValue.x, forKey: Key.originX)
            defaults.set(newValue.y, forKey: Key.originY)
            defaults.set(true, forKey: Key.hasOrigin)
        }
    }

    var monitorEnabled: Bool {
        get { defaults.bool(forKey: Key.monitorEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.monitorEnabled) }
    }

    var monitorProvider: AgentProvider? {
        get { defaults.string(forKey: Key.monitorProvider).flatMap(AgentProvider.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: Key.monitorProvider) }
    }

    /// Migrates the former multi-provider preference without selecting a
    /// provider on the user's behalf when the old value is ambiguous.
    func migrateLegacyMonitorProviderIfNeeded() {
        guard defaults.object(forKey: Key.monitorProvider) == nil,
              defaults.object(forKey: Key.monitorProviders) != nil
        else { return }
        let legacy = (defaults.stringArray(forKey: Key.monitorProviders) ?? []).compactMap(AgentProvider.init(rawValue:))
        switch MonitorProviderMigration.fromLegacyProviders(legacy) {
        case .requiresReconfiguration:
            defaults.set(false, forKey: Key.monitorEnabled)
        case let .selected(provider):
            defaults.set(provider.rawValue, forKey: Key.monitorProvider)
            defaults.removeObject(forKey: Key.monitorProviders)
        }
    }

    var monitorBubbleCollapsed: Bool {
        get { defaults.bool(forKey: Key.monitorBubbleCollapsed) }
        nonmutating set { defaults.set(newValue, forKey: Key.monitorBubbleCollapsed) }
    }

    var autonomyEnabled: Bool {
        get { defaults.object(forKey: Key.autonomyEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.autonomyEnabled) }
    }

    var showsStatusItem: Bool {
        get { defaults.object(forKey: Key.showsStatusItem) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.showsStatusItem) }
    }

    /// Optional custom pets library path. Ignored when `--pets-dir` is passed on launch.
    var petsDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Key.petsDirectory)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
            else { return nil }
            return URL(
                fileURLWithPath: (path as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.path, forKey: Key.petsDirectory)
            } else {
                defaults.removeObject(forKey: Key.petsDirectory)
            }
        }
    }

    var budgetConfigurations: [UsageProvider: ProviderBudgetConfiguration] {
        get {
            guard let data = defaults.data(forKey: Key.budgets), let values = try? JSONDecoder().decode([String: ProviderBudgetConfiguration].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: values.compactMap { entry in
                UsageProvider(rawValue: entry.key).map { ($0, entry.value) }
            })
        }
        nonmutating set {
            let values = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(values), forKey: Key.budgets)
        }
    }

    func isProviderEnabled(_ provider: UsageProvider) -> Bool {
        providerToggles()[provider.rawValue] ?? true
    }

    func setProviderEnabled(_ provider: UsageProvider, enabled: Bool) {
        var toggles = providerToggles()
        toggles[provider.rawValue] = enabled
        defaults.set(toggles, forKey: Key.providerToggles)
    }

    var enabledProviders: Set<UsageProvider> {
        Set(UsageProvider.allCases.filter(isProviderEnabled))
    }

    private func providerToggles() -> [String: Bool] {
        (defaults.dictionary(forKey: Key.providerToggles) as? [String: Bool]) ?? [:]
    }

    var autonomyConfiguration: AutonomyConfiguration {
        get {
            let defaultConfiguration = AutonomyConfiguration.default
            let minimumWait = defaults.object(forKey: Key.autonomyMinimumWait) == nil
                ? defaultConfiguration.minimumWait
                : defaults.double(forKey: Key.autonomyMinimumWait)
            let maximumWait = defaults.object(forKey: Key.autonomyMaximumWait) == nil
                ? defaultConfiguration.maximumWait
                : defaults.double(forKey: Key.autonomyMaximumWait)
            let enabledActions = defaults.stringArray(forKey: Key.autonomyEnabledActions)
                .map { Set($0.compactMap(AutonomousActionKind.init(rawValue:))) }
                ?? defaultConfiguration.enabledActions
            return AutonomyConfiguration(
                minimumWait: minimumWait,
                maximumWait: maximumWait,
                enabledActions: enabledActions
            ) ?? defaultConfiguration
        }
        nonmutating set {
            defaults.set(newValue.minimumWait, forKey: Key.autonomyMinimumWait)
            defaults.set(newValue.maximumWait, forKey: Key.autonomyMaximumWait)
            defaults.set(newValue.enabledActions.map(\.rawValue), forKey: Key.autonomyEnabledActions)
        }
    }
}
