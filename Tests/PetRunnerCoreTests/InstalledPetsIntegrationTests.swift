import Foundation
import Testing
@testable import PetRunnerCore

struct InstalledPetsIntegrationTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["PETRUNNER_RUN_INSTALLED_PET_TESTS"] == "1",
        "Set PETRUNNER_RUN_INSTALLED_PET_TESTS=1 to scan installed pets"
    ))
    func installedCodexPetsLoadWhenExplicitlyEnabled() {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let result = PetLibrary().scan(at: codexHome.appendingPathComponent("pets", isDirectory: true))

        #expect(!result.valid.isEmpty)
        #expect(result.invalid.isEmpty, "\(result.invalid.map(\.message).joined(separator: "\n"))")
        #expect(result.valid.contains { $0.version == .v1 })
        #expect(result.valid.contains { $0.version == .v2 })
    }
}
