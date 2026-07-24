import Foundation
import PetRunnerCore

/// One-shot preferences written by `npx @hdminh/pet-runner` before launch.
struct CLISetupFile: Decodable {
    var version: Int?
    var petsDirectory: String?
    var selectedPetID: String?
    var monitorEnabled: Bool?
    var monitorProvider: String?
    var usageProviders: [String: Bool]?
    var autonomyEnabled: Bool?
    var showsStatusItem: Bool?
}

enum CLISetupStore {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PetRunner/cli-setup.json", isDirectory: false)
    }

    static func load() -> CLISetupFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CLISetupFile.self, from: data)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

struct CLISetupApplication {
    var preferencesApplied = false
    var monitorProvider: AgentProvider?
    var shouldEnableMonitor = false

    mutating func applyPreferences(_ preferences: PetRunnerPreferences) {
        guard let setup = CLISetupStore.load() else { return }
        preferencesApplied = true

        if let petsDirectory = nonempty(setup.petsDirectory) {
            preferences.petsDirectory = URL(
                fileURLWithPath: (petsDirectory as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        if let selectedPetID = nonempty(setup.selectedPetID) {
            preferences.selectedPetID = selectedPetID
        }
        if let autonomyEnabled = setup.autonomyEnabled {
            preferences.autonomyEnabled = autonomyEnabled
        }
        if let showsStatusItem = setup.showsStatusItem {
            preferences.showsStatusItem = showsStatusItem
        }
        if let usageProviders = setup.usageProviders {
            for provider in UsageProvider.allCases {
                if let enabled = usageProviders[provider.rawValue] {
                    preferences.setProviderEnabled(provider, enabled: enabled)
                }
            }
        }

        let wantsMonitor = setup.monitorEnabled == true
        let provider = setup.monitorProvider.flatMap(AgentProvider.init(rawValue:))
        if wantsMonitor, let provider {
            preferences.monitorProvider = provider
            preferences.monitorEnabled = true
            shouldEnableMonitor = true
            monitorProvider = provider
        } else if setup.monitorEnabled == false {
            preferences.monitorEnabled = false
            preferences.monitorProvider = nil
            shouldEnableMonitor = false
        }

        CLISetupStore.remove()
    }

    private func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
