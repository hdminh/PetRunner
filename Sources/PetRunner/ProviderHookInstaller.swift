import Foundation
import PetRunnerCore

struct ProviderHookInstaller {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func install(_ providers: [AgentProvider], executablePath: String) throws {
        var installed: [AgentProvider] = []
        do {
            for provider in providers {
                try update(provider, executablePath: executablePath, removing: false)
                installed.append(provider)
            }
        } catch {
            for provider in installed { try? update(provider, executablePath: executablePath, removing: true) }
            throw error
        }
    }

    func removeAll() throws {
        for provider in AgentProvider.allCases {
            try update(provider, executablePath: "", removing: true)
        }
    }

    private func update(_ provider: AgentProvider, executablePath: String, removing: Bool) throws {
        let config = ProviderHookConfiguration(provider: provider)
        let url = home.appendingPathComponent(config.configRelativePath)
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path)
        guard exists || !removing else { return }
        if exists {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        let originalPermissions = exists
            ? try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
            : nil
        let input = exists ? try Data(contentsOf: url) : Data("{}".utf8)
        let output = try (removing ? config.remove(from: input) : config.install(into: input, executablePath: executablePath))
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if exists {
            try input.write(to: url.appendingPathExtension("petrunner-backup"), options: .atomic)
        }
        try output.write(to: url, options: .atomic)
        if let permissions = originalPermissions {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
