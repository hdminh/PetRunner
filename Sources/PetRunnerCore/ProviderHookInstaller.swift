import Foundation

public struct ProviderHookInstallError: LocalizedError {
    public let provider: AgentProvider
    public let path: String
    public let reason: String

    public var errorDescription: String? {
        "\(provider.displayLabel) hook configuration at \(path): \(reason)"
    }
}

public struct ProviderHookInstaller {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func install(_ providers: [AgentProvider], executablePath: String) throws {
        let updates = try unique(providers).compactMap { provider in
            try preparedUpdate(provider, executablePath: executablePath, removing: false)
        }
        try write(updates)
    }

    /// Changes the active monitor provider as one prepared write. Existing
    /// third-party hooks remain untouched; only PetRunner-owned hooks for the
    /// other providers are removed.
    public func replace(with provider: AgentProvider, executablePath: String) throws {
        var updates = try AgentProvider.allCases
            .filter { $0 != provider }
            .compactMap { try preparedUpdate($0, executablePath: "", removing: true) }
        if let selected = try preparedUpdate(provider, executablePath: executablePath, removing: false) {
            updates.append(selected)
        }
        try write(updates)
    }

    public func removeAll() throws {
        let updates = try AgentProvider.allCases.compactMap { provider in
            try preparedUpdate(provider, executablePath: "", removing: true)
        }
        try write(updates)
    }

    private func preparedUpdate(
        _ provider: AgentProvider,
        executablePath: String,
        removing: Bool
    ) throws -> PreparedUpdate? {
        let configuration = ProviderHookConfiguration(provider: provider)
        let url = home.appendingPathComponent(configuration.configRelativePath)
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path)
        guard exists || !removing else { return nil }

        do {
            if exists {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
            }
            let permissions = exists
                ? try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                : nil
            let input = exists ? try Data(contentsOf: url) : Data("{}".utf8)
            let output = try (removing
                ? configuration.remove(from: input)
                : configuration.install(into: input, executablePath: executablePath))
            if !removing {
                try configuration.verifyInstalled(in: output, executablePath: executablePath)
            }
            return PreparedUpdate(
                provider: provider,
                configuration: configuration,
                url: url,
                existed: exists,
                input: input,
                output: output,
                permissions: permissions,
                executablePath: executablePath,
                removing: removing
            )
        } catch let error as ProviderHookInstallError {
            throw error
        } catch {
            throw ProviderHookInstallError(provider: provider, path: url.path, reason: error.localizedDescription)
        }
    }

    private func write(_ updates: [PreparedUpdate]) throws {
        var written: [PreparedUpdate] = []
        do {
            for update in updates {
                try assertUnchangedSincePreflight(update)
                written.append(update)
                try write(update)
            }
        } catch {
            let restorationFailures = restore(written)
            throw reportedError(
                error,
                fallbackUpdate: written.last,
                restorationFailures: restorationFailures
            )
        }
    }

    private func assertUnchangedSincePreflight(_ update: PreparedUpdate) throws {
        let fileManager = FileManager.default
        if update.existed {
            guard fileManager.fileExists(atPath: update.url.path),
                  try Data(contentsOf: update.url) == update.input
            else {
                throw ProviderHookInstallError(
                    provider: update.provider,
                    path: update.url.path,
                    reason: "configuration changed while PetRunner was preparing the hook update"
                )
            }
        } else if fileManager.fileExists(atPath: update.url.path) {
            throw ProviderHookInstallError(
                provider: update.provider,
                path: update.url.path,
                reason: "configuration was created while PetRunner was preparing the hook update"
            )
        }
    }

    private func reportedError(
        _ error: Error,
        fallbackUpdate: PreparedUpdate?,
        restorationFailures: [String]
    ) -> ProviderHookInstallError {
        let baseError: ProviderHookInstallError
        if let error = error as? ProviderHookInstallError {
            baseError = error
        } else {
            baseError = ProviderHookInstallError(
                provider: fallbackUpdate?.provider ?? .cursor,
                path: fallbackUpdate?.url.path ?? home.path,
                reason: error.localizedDescription
            )
        }
        guard !restorationFailures.isEmpty else { return baseError }
        return ProviderHookInstallError(
            provider: baseError.provider,
            path: baseError.path,
            reason: "\(baseError.reason). PetRunner could not restore: \(restorationFailures.joined(separator: "; "))"
        )
    }

    private func write(_ update: PreparedUpdate) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: update.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if update.existed {
            try update.input.write(to: update.url.appendingPathExtension("petrunner-backup"), options: .atomic)
        }
        try update.output.write(to: update.url, options: .atomic)
        if let permissions = update.permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: update.url.path)
        } else {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: update.url.path)
        }
        guard !update.removing else { return }
        let reloaded = try Data(contentsOf: update.url)
        do {
            try update.configuration.verifyInstalled(in: reloaded, executablePath: update.executablePath)
        } catch {
            throw ProviderHookInstallError(provider: update.provider, path: update.url.path, reason: error.localizedDescription)
        }
    }

    private func restore(_ updates: [PreparedUpdate]) -> [String] {
        let fileManager = FileManager.default
        var failures: [String] = []
        for update in updates.reversed() {
            do {
                if update.existed {
                    try update.input.write(to: update.url, options: .atomic)
                    if let permissions = update.permissions {
                        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: update.url.path)
                    }
                } else if fileManager.fileExists(atPath: update.url.path) {
                    try fileManager.removeItem(at: update.url)
                }
            } catch {
                failures.append("\(update.url.path) (\(error.localizedDescription))")
            }
        }
        return failures
    }

    private func unique(_ providers: [AgentProvider]) -> [AgentProvider] {
        var seen = Set<AgentProvider>()
        return providers.filter { seen.insert($0).inserted }
    }
}

private struct PreparedUpdate {
    let provider: AgentProvider
    let configuration: ProviderHookConfiguration
    let url: URL
    let existed: Bool
    let input: Data
    let output: Data
    let permissions: NSNumber?
    let executablePath: String
    let removing: Bool
}
