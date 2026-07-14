import Foundation

public enum ProviderHookError: Error, Equatable, Sendable {
    case malformedJSON
    case unsupportedRoot
    case unsupportedHookShape
    case unsupportedCursorVersion
    case missingInstalledHook
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
        case .claude:
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure"]
        case .codex:
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop"]
        case .cursor:
            ["sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop", "sessionEnd"]
        }
    }

    public var requiresNeutralJSONOutput: Bool { provider == .cursor }

    public func command(executablePath: String, event: String) -> String {
        "\(shellQuoted(executablePath)) --agent-monitor-hook --provider \(provider.rawValue) --event \(shellQuoted(event)) \(Self.ownershipMarker)"
    }

    public func install(into data: Data, executablePath: String) throws -> Data {
        var root = try rootObject(from: data)
        try validateProviderRoot(root)
        var hooks = try hooks(from: root)
        try removeOwnedEntries(from: &hooks)

        for event in events {
            hooks[event] = try updating(entries: hooks[event], event: event, executablePath: executablePath)
        }
        root["hooks"] = hooks
        if provider == .cursor { root["version"] = 1 }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }

    public func remove(from data: Data) throws -> Data {
        var root = try rootObject(from: data)
        try validateProviderRoot(root)
        var hooks = try hooks(from: root)
        try removeOwnedEntries(from: &hooks)
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }

    public func verifyInstalled(in data: Data, executablePath: String) throws {
        let root = try rootObject(from: data)
        try validateProviderRoot(root)
        let hooks = try hooks(from: root)
        for event in events {
            guard let entries = hooks[event] as? [[String: Any]] else { throw ProviderHookError.missingInstalledHook }
            let expectedCommand = command(executablePath: executablePath, event: event)
            guard entries.contains(where: { contains(command: expectedCommand, in: $0) }) else {
                throw ProviderHookError.missingInstalledHook
            }
        }
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

        return status.map {
            NormalizedAgentEvent(
                provider: provider,
                sessionID: sessionID,
                status: $0,
                displayName: displayNameCandidate(in: payload, eventName: loweredEvent)
            )
        }
    }

    private func rootObject(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw ProviderHookError.malformedJSON }
        guard let root = object as? [String: Any] else { throw ProviderHookError.unsupportedRoot }
        return root
    }

    private func validateProviderRoot(_ root: [String: Any]) throws {
        guard provider == .cursor else { return }
        guard let rawVersion = root["version"] else { return }
        guard let version = rawVersion as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1
        else { throw ProviderHookError.unsupportedCursorVersion }
    }

    private func hooks(from root: [String: Any]) throws -> [String: Any] {
        guard let hooks = root["hooks"] else { return [:] }
        guard let typed = hooks as? [String: Any] else { throw ProviderHookError.unsupportedHookShape }
        for value in typed.values where !(value is [[String: Any]]) {
            throw ProviderHookError.unsupportedHookShape
        }
        return typed
    }

    private func removeOwnedEntries(from hooks: inout [String: Any]) throws {
        for event in Array(hooks.keys) {
            guard let entries = hooks[event] as? [[String: Any]] else { throw ProviderHookError.unsupportedHookShape }
            let cleaned = try entries.compactMap(removeOwnedEntry)
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }
    }

    private func removeOwnedEntry(_ entry: [String: Any]) throws -> [String: Any]? {
        if let command = entry["command"] {
            guard let typedCommand = command as? String else { throw ProviderHookError.unsupportedHookShape }
            return typedCommand.contains(Self.ownershipMarker) ? nil : entry
        }
        guard let rawNestedHooks = entry["hooks"] else { return entry }
        guard let nestedHooks = rawNestedHooks as? [[String: Any]] else { throw ProviderHookError.unsupportedHookShape }
        let cleanedNestedHooks = try nestedHooks.compactMap { nestedHook -> [String: Any]? in
            if let command = nestedHook["command"] {
                guard let typedCommand = command as? String else { throw ProviderHookError.unsupportedHookShape }
                return typedCommand.contains(Self.ownershipMarker) ? nil : nestedHook
            }
            return nestedHook
        }
        guard !cleanedNestedHooks.isEmpty else { return nil }
        var cleanedEntry = entry
        cleanedEntry["hooks"] = cleanedNestedHooks
        return cleanedEntry
    }

    private func updating(entries: Any?, event: String, executablePath: String) throws -> [[String: Any]] {
        let existing: [[String: Any]]
        if let entries {
            guard let typed = entries as? [[String: Any]] else { throw ProviderHookError.unsupportedHookShape }
            existing = typed
        } else {
            existing = []
        }
        let command = command(executablePath: executablePath, event: event)
        if provider == .claude || provider == .codex {
            return existing + [["hooks": [["type": "command", "command": command]]]]
        }
        return existing + [["command": command]]
    }

    private func contains(command expectedCommand: String, in entry: [String: Any]) -> Bool {
        if entry["command"] as? String == expectedCommand { return true }
        let nestedHooks = entry["hooks"] as? [[String: Any]] ?? []
        return nestedHooks.contains { $0["command"] as? String == expectedCommand }
    }

    private func displayNameCandidate(in payload: [String: Any], eventName: String) -> AgentSessionDisplayName? {
        let isPromptEvent: Bool
        switch provider {
        case .claude, .codex:
            isPromptEvent = eventName == "userpromptsubmit"
        case .cursor:
            isPromptEvent = eventName == "beforesubmitprompt"
        }
        guard isPromptEvent, let prompt = payload["prompt"] as? String else { return nil }
        return AgentSessionDisplayName.sanitized(prompt, source: .prompt)
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
