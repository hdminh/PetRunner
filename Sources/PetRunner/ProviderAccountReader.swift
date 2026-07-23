import Foundation
import PetRunnerCore
import Security

struct ProviderAccountSnapshot: Equatable, Sendable {
    var connected: Bool
    var email: String?
    var displayName: String?
    var plan: String?
    var organization: String?
    var source: String
    var status: String
    var updatedAt: Date?
}

enum ProviderAccountReader {
    static func account(
        for provider: UsageProvider,
        cursorStatus: String? = nil,
        cursorMessage: String? = nil
    ) -> ProviderAccountSnapshot {
        switch provider {
        case .cursor:
            return cursorAccount(status: cursorStatus, message: cursorMessage)
        case .codex:
            return codexAccount()
        case .claude:
            return claudeAccount()
        }
    }

    private static func cursorAccount(status: String?, message: String?) -> ProviderAccountSnapshot {
        let store = CursorAppAuthStore()
        let email = store.cachedEmail()
        let plan = store.membershipType().map { $0.capitalized }
        let connected = status == "connected" || email != nil || ((try? store.cookieHeader()) != nil)
        let resolvedStatus: String
        switch status {
        case "connected":
            resolvedStatus = "Signed in"
        case "disabled":
            resolvedStatus = "Disabled"
        case "error":
            resolvedStatus = message ?? "Refresh failed"
        case "notConnected":
            resolvedStatus = "Not connected"
        default:
            resolvedStatus = connected ? "Signed in" : "Not connected"
        }
        return ProviderAccountSnapshot(
            connected: connected && status != "disabled",
            email: email,
            displayName: email,
            plan: plan,
            organization: nil,
            source: "Cursor.app local auth",
            status: resolvedStatus,
            updatedAt: nil
        )
    }

    private static func codexAccount() -> ProviderAccountSnapshot {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ProviderAccountSnapshot(
                connected: false,
                email: nil,
                displayName: nil,
                plan: nil,
                organization: nil,
                source: "Codex auth.json",
                status: "Not signed in",
                updatedAt: modificationDate(at: url)
            )
        }

        let tokens = object["tokens"] as? [String: Any] ?? [:]
        let claims = jwtClaims(tokens["id_token"] as? String)
        let openaiAuth = claims?["https://api.openai.com/auth"] as? [String: Any]
        let email = nonempty(claims?["email"] as? String)
        let displayName = nonempty(claims?["name"] as? String) ?? email
        let plan = nonempty(openaiAuth?["chatgpt_plan_type"] as? String)?.capitalized
        let organizations = openaiAuth?["organizations"] as? [[String: Any]]
        let organization = organizations?.compactMap { nonempty($0["title"] as? String) ?? nonempty($0["name"] as? String) }.first
        let connected = email != nil || tokens["access_token"] != nil
        return ProviderAccountSnapshot(
            connected: connected,
            email: email,
            displayName: displayName,
            plan: plan,
            organization: organization,
            source: "ChatGPT auth",
            status: connected ? "Signed in" : "Not signed in",
            updatedAt: modificationDate(at: url)
        )
    }

    private static func claudeAccount() -> ProviderAccountSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let hasSettings = FileManager.default.fileExists(atPath: settingsURL.path)
        let hasCredentials = claudeCredentialsPresent()
        let connected = hasSettings || hasCredentials
        return ProviderAccountSnapshot(
            connected: connected,
            email: nil,
            displayName: connected ? "Claude Code" : nil,
            plan: nil,
            organization: nil,
            source: "Local Claude config",
            status: connected ? "Signed in" : "Not signed in",
            updatedAt: modificationDate(at: settingsURL)
        )
    }

    private static func claudeCredentialsPresent() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private static func jwtClaims(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func modificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
