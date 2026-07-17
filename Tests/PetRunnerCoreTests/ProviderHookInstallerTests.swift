@testable import PetRunnerCore
import Foundation
import Testing

struct ProviderHookInstallerTests {
    @Test func installsAndVerifiesCursorHooksWithoutRemovingThirdPartyEntries() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = home.appendingPathComponent(".cursor/hooks.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\":1,\"hooks\":{\"stop\":[{\"command\":\"other-command\"}]}}".utf8).write(to: configURL)

        let installer = ProviderHookInstaller(home: home)
        try installer.install([.cursor], executablePath: "/tmp/PetRunner")

        let installed = try Data(contentsOf: configURL)
        let configuration = ProviderHookConfiguration(provider: .cursor)
        try configuration.verifyInstalled(in: installed, executablePath: "/tmp/PetRunner")
        let root = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
        let hooks = try #require(root["hooks"] as? [String: Any])
        let stopEntries = try #require(hooks["stop"] as? [[String: Any]])
        #expect(stopEntries.contains { $0["command"] as? String == "other-command" })

        try installer.install([.cursor], executablePath: "/tmp/PetRunner")
        #expect(try Data(contentsOf: configURL) == installed)
    }

    @Test func preflightFailureLeavesEarlierProviderConfigUntouched() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        let cursorURL = home.appendingPathComponent(".cursor/hooks.json")
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalClaude = Data("{\"other\":true}".utf8)
        try originalClaude.write(to: claudeURL)
        try Data("[]".utf8).write(to: cursorURL)

        #expect(throws: ProviderHookInstallError.self) {
            try ProviderHookInstaller(home: home).install([.claude, .cursor], executablePath: "/tmp/PetRunner")
        }
        #expect(try Data(contentsOf: claudeURL) == originalClaude)
    }

    @Test func preservesExistingConfigPermissionsAfterAtomicInstall() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: configURL.path)

        try ProviderHookInstaller(home: home).install([.claude], executablePath: "/tmp/PetRunner")

        let permissions = try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o640)
        try ProviderHookConfiguration(provider: .claude).verifyInstalled(
            in: Data(contentsOf: configURL),
            executablePath: "/tmp/PetRunner"
        )
    }

    @Test func switchingProviderRemovesOnlyOtherPetRunnerOwnedHooks() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = ProviderHookInstaller(home: home)
        try installer.install([.claude], executablePath: "/tmp/PetRunner")
        let cursorURL = home.appendingPathComponent(".cursor/hooks.json")
        try FileManager.default.createDirectory(at: cursorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\":1,\"hooks\":{\"stop\":[{\"command\":\"other-command\"}]}}".utf8).write(to: cursorURL)

        try installer.replace(with: .cursor, executablePath: "/tmp/PetRunner")

        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        let claude = try Data(contentsOf: claudeURL)
        #expect(!String(decoding: claude, as: UTF8.self).contains(ProviderHookConfiguration.ownershipMarker))
        let cursor = try Data(contentsOf: cursorURL)
        try ProviderHookConfiguration(provider: .cursor).verifyInstalled(in: cursor, executablePath: "/tmp/PetRunner")
        #expect(String(decoding: cursor, as: UTF8.self).contains("other-command"))
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("petrunner-hooks-\(UUID().uuidString)")
    }
}
