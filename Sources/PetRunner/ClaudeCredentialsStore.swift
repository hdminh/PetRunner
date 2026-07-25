import Darwin
import Foundation
import LocalAuthentication
import Security

/// Reads Claude Code OAuth credentials without re-prompting on every launch.
///
/// Mirrors CodexBar's approach, with a stricter silent path for ad-hoc builds:
/// - Prefer `~/.claude/.credentials.json` when present
/// - Cache the token blob in Application Support (not Keychain) so ad-hoc
///   re-signing via `build_and_run.sh` does not invalidate access
/// - Launch / timer / dashboard poll must NEVER query Claude's Keychain item.
///   `KeychainNoUIQuery` is not reliable for foreign ACL items on some macOS
///   builds and still surfaces Allow/Deny sheets.
/// - Interactive Claude Keychain access is only for explicit user actions
///   (`allowPrompt: true`), then immediately cached to Application Support.
/// - Never touch `vn.hodinhminh.petrunner.claude-credentials`: bare
///   SecItemDelete/CopyMatching on that ACL-bound item re-prompts after
///   ad-hoc re-sign. File cache / `~/.claude` only.
enum ClaudeCredentialsStore {
    private static let claudeService = "Claude Code-credentials"
    private static let fileCacheName = "claude-oauth-cache.json"
    private static let memory = MemoryBox()
    private static let accessLock = NSLock()

    /// Access token for Anthropic OAuth APIs.
    /// - Parameter allowPrompt: When `true`, may show a Keychain dialog once
    ///   for Claude Code's item (user-initiated refresh). Launch/timer paths
    ///   should pass `false`. Never touches the PetRunner legacy Keychain item.
    static func accessToken(allowPrompt: Bool = false) -> String? {
        accessLock.lock()
        defer { accessLock.unlock() }

        if let fileToken = token(from: credentialsFileObject()) {
            return fileToken
        }

        if let cached = memory.get() ?? loadFileCache() {
            memory.set(cached)
            if let token = token(from: cached.object) {
                // Background paths keep serving a near-expired cache instead of
                // re-prompting Claude's Keychain item on every launch.
                if !cached.isExpired || !allowPrompt {
                    return token
                }
            }
        }

        // Silent callers stop here. Probing Claude Code-credentials — even with
        // KeychainNoUIQuery — can still show an Allow/Deny sheet for ad-hoc
        // signed PetRunner binaries after each rebuild.
        guard allowPrompt else {
            return memory.get().flatMap { token(from: $0.object) }
                ?? loadFileCache().flatMap { token(from: $0.object) }
        }

        // Explicit Refresh: try a no-UI probe first, then one interactive read.
        if let object = loadClaudeKeychainObject(allowPrompt: false)
            ?? loadClaudeKeychainObject(allowPrompt: true)
        {
            let credentials = CachedCredentials(object: object, modifiedAt: claudeKeychainModifiedAt())
            persistCache(credentials)
            return token(from: object)
        }

        return memory.get().flatMap { token(from: $0.object) }
            ?? loadFileCache().flatMap { token(from: $0.object) }
    }

    /// Presence check that never presents a keychain prompt and never touches
    /// Claude's Keychain item (dashboard polls this every few seconds).
    static func credentialsPresent() -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        if credentialsFileObject() != nil { return true }
        if memory.get() != nil || loadFileCache() != nil { return true }
        return false
    }

    static func invalidateCache() {
        accessLock.lock()
        defer { accessLock.unlock() }
        memory.set(nil)
        try? FileManager.default.removeItem(at: fileCacheURL)
    }

    // MARK: - Sources

    private static func credentialsFileObject() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func loadClaudeKeychainObject(allowPrompt: Bool) -> [String: Any]? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if !allowPrompt {
            KeychainNoUIQuery.apply(to: &query)
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func claudeKeychainModifiedAt() -> Date? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    // MARK: - Application Support cache (CodexBar-style; survives ad-hoc re-sign)

    private static var fileCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PetRunner", isDirectory: true)
            .appendingPathComponent(fileCacheName, isDirectory: false)
    }

    private static func loadFileCache() -> CachedCredentials? {
        readFileCache()
    }

    private static func persistCache(_ credentials: CachedCredentials) {
        memory.set(credentials)
        saveFileCache(credentials)
    }

    private static func readFileCache() -> CachedCredentials? {
        let url = fileCacheURL
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = envelope["credentials"] as? [String: Any]
        else { return nil }
        let modifiedAt: Date?
        if let interval = envelope["sourceModifiedAt"] as? TimeInterval {
            modifiedAt = Date(timeIntervalSince1970: interval)
        } else {
            modifiedAt = nil
        }
        return CachedCredentials(object: object, modifiedAt: modifiedAt)
    }

    private static func saveFileCache(_ credentials: CachedCredentials) {
        guard let credentialsData = try? JSONSerialization.data(withJSONObject: credentials.object),
              let credentialsObject = try? JSONSerialization.jsonObject(with: credentialsData) as? [String: Any]
        else { return }
        var envelope: [String: Any] = ["credentials": credentialsObject]
        if let modifiedAt = credentials.modifiedAt {
            envelope["sourceModifiedAt"] = modifiedAt.timeIntervalSince1970
        }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        let directory = fileCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileCacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileCacheURL.path)
    }

    // MARK: - Parsing

    private static func token(from object: [String: Any]?) -> String? {
        guard let object else { return nil }
        if let oauth = object["claudeAiOauth"] as? [String: Any] {
            return nonempty(oauth["accessToken"] as? String) ?? nonempty(oauth["access_token"] as? String)
        }
        return nonempty(object["accessToken"] as? String) ?? nonempty(object["access_token"] as? String)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct CachedCredentials {
        var object: [String: Any]
        var modifiedAt: Date?

        var isExpired: Bool {
            let oauth = object["claudeAiOauth"] as? [String: Any] ?? object
            guard let raw = oauth["expiresAt"] ?? oauth["expires_at"] else { return false }
            let expiresAt: Date?
            if let number = raw as? NSNumber {
                let value = number.doubleValue
                // Claude stores milliseconds; accept seconds too.
                expiresAt = Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
            } else if let string = raw as? String, let value = Double(string) {
                expiresAt = Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
            } else {
                expiresAt = nil
            }
            guard let expiresAt else { return false }
            return expiresAt <= Date().addingTimeInterval(60)
        }
    }

    private final class MemoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CachedCredentials?

        func get() -> CachedCredentials? {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func set(_ next: CachedCredentials?) {
            lock.lock(); defer { lock.unlock() }
            value = next
        }
    }

}

/// CodexBar `KeychainNoUIQuery`: `interactionNotAllowed` alone can still surface
/// Allow/Deny prompts on some macOS builds; also set `kSecUseAuthenticationUIFail`.
private enum KeychainNoUIQuery {
    private static let uiFailPolicy = resolveUIFailPolicy()

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }

    private static func resolveUIFailPolicy() -> String {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }
}
