import Foundation
import PetRunnerCore

enum ProviderQuotaClient {
    static func fetchAll(
        enabled: Set<UsageProvider>,
        now: Date = .now,
        allowClaudeKeychainPrompt: Bool = false
    ) async -> [UsageProvider: ProviderQuotaSnapshot] {
        await withTaskGroup(of: (UsageProvider, ProviderQuotaSnapshot).self) { group in
            if enabled.contains(.claude) {
                group.addTask { (.claude, await fetchClaude(now: now, allowKeychainPrompt: allowClaudeKeychainPrompt)) }
            }
            if enabled.contains(.codex) {
                group.addTask { (.codex, await fetchCodex(now: now)) }
            }
            if enabled.contains(.cursor) {
                group.addTask { (.cursor, await fetchCursor(now: now)) }
            }
            var result: [UsageProvider: ProviderQuotaSnapshot] = [:]
            for await (provider, snapshot) in group {
                result[provider] = snapshot
            }
            return result
        }
    }

    static func fetchClaude(now: Date = .now, allowKeychainPrompt: Bool = false) async -> ProviderQuotaSnapshot {
        guard let token = ClaudeCredentialsStore.accessToken(allowPrompt: allowKeychainPrompt) else {
            return .unavailable(source: "oauth", message: "Sign in to Claude Code to load plan quota.", updatedAt: now)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable(source: "oauth", message: "Claude quota request failed.", updatedAt: now)
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    ClaudeCredentialsStore.invalidateCache()
                    // Only re-prompt Claude Keychain on explicit user refresh
                    // (CodexBar `onlyOnUserAction`). Launch/timer stay silent.
                    if allowKeychainPrompt,
                       let refreshed = ClaudeCredentialsStore.accessToken(allowPrompt: true),
                       refreshed != token
                    {
                        return await fetchClaude(now: now, allowKeychainPrompt: false)
                    }
                    return .unavailable(source: "oauth", message: "Claude OAuth token needs re-auth (user:profile).", updatedAt: now)
                }
                return .unavailable(source: "oauth", message: "Claude quota unavailable (\(http.statusCode)).", updatedAt: now)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unavailable(source: "oauth", message: "Claude quota response was invalid.", updatedAt: now)
            }
            return ProviderQuotaParser.parseClaudeUsage(object, now: now)
        } catch {
            return .unavailable(source: "oauth", message: "Claude quota could not be refreshed.", updatedAt: now)
        }
    }

    static func fetchCodex(now: Date = .now) async -> ProviderQuotaSnapshot {
        guard let auth = codexAuth() else {
            return .unavailable(source: "oauth", message: "Sign in to Codex / ChatGPT to load plan quota.", updatedAt: now)
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .unavailable(source: "oauth", message: "Codex quota unavailable.", updatedAt: now)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unavailable(source: "oauth", message: "Codex quota response was invalid.", updatedAt: now)
            }
            return ProviderQuotaParser.parseCodexWhamUsage(object, now: now)
        } catch {
            return .unavailable(source: "oauth", message: "Codex quota could not be refreshed.", updatedAt: now)
        }
    }

    static func fetchCursor(now: Date = .now) async -> ProviderQuotaSnapshot {
        guard let cookie = try? CursorAppAuthStore().cookieHeader() else {
            return .unavailable(source: "localAuth", message: "Sign in to Cursor.app to load plan quota.", updatedAt: now)
        }
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .unavailable(source: "localAuth", message: "Cursor quota unavailable.", updatedAt: now)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unavailable(source: "localAuth", message: "Cursor quota response was invalid.", updatedAt: now)
            }
            return ProviderQuotaParser.parseCursorUsageSummary(object, now: now)
        } catch {
            return .unavailable(source: "localAuth", message: "Cursor quota could not be refreshed.", updatedAt: now)
        }
    }

    private static func codexAuth() -> (accessToken: String, accountID: String?)? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let tokens = object["tokens"] as? [String: Any] ?? [:]
        guard let accessToken = nonempty(tokens["access_token"] as? String) else { return nil }
        let accountID = nonempty(tokens["account_id"] as? String)
            ?? nonempty(object["account_id"] as? String)
            ?? chatgptAccountID(from: tokens["id_token"] as? String)
        return (accessToken, accountID)
    }

    private static func chatgptAccountID(from idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return nonempty(auth["chatgpt_account_id"] as? String)
            ?? nonempty(auth["account_id"] as? String)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
