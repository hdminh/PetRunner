import Foundation
import PetRunnerCore

enum CLISetupCommand {
    /// Applies `cli-setup.json` from the npm CLI without opening the overlay.
    /// Used after `npx @hdminh/pet-runner install` so preferences and monitor
    /// hooks exist before the first interactive launch.
    static func apply() -> Int32 {
        let preferences = PetRunnerPreferences()
        var application = CLISetupApplication()
        application.applyPreferences(preferences)

        if application.shouldEnableMonitor, let provider = application.monitorProvider {
            do {
                try installMonitorHooks(provider: provider)
            } catch {
                fputs("pet-runner: failed to install monitor hooks: \(error.localizedDescription)\n", stderr)
                return 1
            }
        } else if application.preferencesApplied, preferences.monitorEnabled == false {
            do {
                try ProviderHookInstaller().removeAll()
            } catch {
                fputs("pet-runner: failed to remove monitor hooks: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        return 0
    }

    private static func installMonitorHooks(provider: AgentProvider) throws {
        guard let executable = Bundle.main.executableURL?.path else {
            throw ProviderHookInstallError(
                provider: provider,
                path: ProviderHookConfiguration(provider: provider).configURL().path,
                reason: "PetRunner executable path is unavailable"
            )
        }
        try ProviderHookInstaller().replace(with: provider, executablePath: executable)
    }
}
