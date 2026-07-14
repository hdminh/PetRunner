import Foundation

public enum ProviderHookError: Error, Equatable, Sendable {
    case malformedJSON
    case unsupportedRoot
    case unsupportedHookShape
}

public struct ProviderHookConfiguration: Sendable {
    public static let ownershipMarker = "--pet-runner-monitor"

    public let provider: AgentProvider

    public init(provider: AgentProvider) {
        self.provider = provider
    }

    public var configRelativePath: String {
        switch provider {
        case .claude: ".claude/settings.json"
        case .codex: ".codex/hooks.json"
        case .cursor: ".cursor/hooks.json"
        }
    }

    public var events: [String] {
        switch provider {
        case .claude: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUseFailure", "Stop", "StopFailure"]
        case .codex: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUseFailure", "Stop", "StopFailure"]
        case .cursor: ["sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUseFailure", "stop", "sessionEnd"]
        }
    }

    public var requiresNeutralJSONOutput: Bool { provider == .cursor }

    public func command(executablePath: String, event: String) -> String {
        "\(shellQuoted(executablePath)) --agent-monitor-hook --provider \(provider.rawValue) --event \(shellQuoted(event)) \(Self.ownershipMarker)"
    }

    public func install(into data: Data, executablePath: String) throws -> Data {
        var root = try rootObject(from: data)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        guard root["hooks"] == nil || root["hooks"] is [String: Any] else { throw ProviderHookError.unsupportedHookShape }

        for event in events {
            let updated = try updating(entries: hooks[event], event: event, executablePath: executablePath)
            hooks[event] = updated
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }

    public func remove(from data: Data) throws -> Data {
        var root = try rootObject(from: data)
        guard var hooks = root["hooks"] as? [String: Any] else { return data }

        for event in Array(hooks.keys) {
            guard let value = hooks[event] else { continue }
            guard var entries = value as? [[String: Any]] else { throw ProviderHookError.unsupportedHookShape }
            entries = entries.compactMap { entry in
                isOwned(entry) ? nil : entry
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }

    public func normalize(payload: [String: Any], eventName: String) -> NormalizedAgentEvent? {
        guard let sessionID = sessionID(in: payload), !sessionID.isEmpty else { return nil }
        let loweredEvent = eventName.lowercased()
        let status: AgentStatus?
        if loweredEvent.contains("permission") { status = provider == .cursor ? nil : .needsApproval }
        else if loweredEvent.contains("failure") || payload["status"] as? String == "error" { status = .failed }
        else if loweredEvent == "stop" || loweredEvent.contains("sessionend") { status = .finished }
        else if loweredEvent.contains("tool") {
            status = isReadOnlyTool(payload["tool_name"] as? String ?? payload["toolName"] as? String) ? .reviewing : .working
        } else if loweredEvent.contains("prompt") || loweredEvent.contains("sessionstart") { status = .working }
        else { status = nil }
        return status.map { NormalizedAgentEvent(provider: provider, sessionID: sessionID, status: $0) }
    }

    private func rootObject(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw ProviderHookError.malformedJSON }
        guard let root = object as? [String: Any] else { throw ProviderHookError.unsupportedRoot }
        return root
    }

    private func updating(entries: Any?, event: String, executablePath: String) throws -> [[String: Any]] {
        let existing: [[String: Any]]
        if let entries {
            guard let typed = entries as? [[String: Any]] else { throw ProviderHookError.unsupportedHookShape }
            existing = typed.filter { !isOwned($0) }
        } else {
            existing = []
        }
        let command = command(executablePath: executablePath, event: event)
        if provider == .claude || provider == .codex {
            return existing + [["hooks": [["type": "command", "command": command]]]]
        }
        return existing + [["command": command]]
    }

    private func isOwned(_ entry: [String: Any]) -> Bool {
        if (entry["command"] as? String)?.contains(Self.ownershipMarker) == true { return true }
        let hooks = entry["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.contains(Self.ownershipMarker) == true }
    }

    private func sessionID(in payload: [String: Any]) -> String? {
        switch provider {
        case .cursor: (payload["conversation_id"] ?? payload["session_id"]) as? String
        case .claude, .codex: payload["session_id"] as? String
        }
    }

    private func isReadOnlyTool(_ tool: String?) -> Bool {
        guard let tool else { return false }
        let normalized = tool.lowercased()
        return ["read", "search", "grep", "glob", "find", "list"].contains { normalized.contains($0) }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}
