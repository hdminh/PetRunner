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
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "SubagentStart", "SubagentStop"]
        case .codex:
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop"]
        case .cursor:
            ["beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop", "sessionEnd", "subagentStart", "subagentStop"]
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
        let loweredEvent = eventName.lowercased()
        // Cursor emits this merely when a chat tab is opened. A request begins
        // at beforeSubmitPrompt, so creating a session here would leave a
        // permanent Thinking bubble for an untouched tab.
        guard !(provider == .cursor && loweredEvent.contains("sessionstart")),
              let sessionID = sessionID(in: payload), !sessionID.isEmpty
        else { return nil }
        if (provider == .claude || provider == .cursor), loweredEvent == "subagentstart" || loweredEvent == "subagentstop" {
            let agentIDKey = provider == .cursor ? "subagent_id" : "agent_id"
            let agentTypeKey = provider == .cursor ? "subagent_type" : "agent_type"
            guard let agentID = payload[agentIDKey] as? String,
                  !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let isStopping = loweredEvent == "subagentstop"
            let agentType = (payload[agentTypeKey] as? String).flatMap(AgentSubagentType.sanitized)
            return NormalizedAgentEvent(
                provider: provider,
                sessionID: sessionID,
                status: isStopping ? .finished : .working,
                model: modelCandidate(in: payload),
                activity: AgentActivity.sanitized(isStopping ? "Subagent finished" : "Subagent started"),
                scope: .subagent(agentID: agentID),
                agentType: agentType,
                lifecycle: isStopping ? .finished : .updated,
                source: .subagentLifecycle,
                sessionName: sessionNameCandidate(in: payload),
                estimatedCost: estimatedCostCandidate(in: payload)
            )
        }
        let status: AgentStatus?
        if loweredEvent.contains("permission") || isWaitingForUserStatus(payload["status"] as? String) { status = provider == .cursor ? nil : .needsApproval }
        else if loweredEvent.contains("failure") || payload["status"] as? String == "error" { status = .failed }
        else if loweredEvent == "stop" || loweredEvent.contains("sessionend") { status = .finished }
        else if loweredEvent.contains("tool") {
            let toolName = payload["tool_name"] as? String ?? payload["toolName"] as? String
            let isWaitingForUser = isUserInputTool(toolName) && (loweredEvent.contains("pretool") || loweredEvent.contains("before"))
            status = isWaitingForUser ? .needsApproval : (isReadOnlyTool(toolName) ? .reviewing : .working)
        } else if loweredEvent.contains("prompt") || loweredEvent.contains("sessionstart") { status = .working }
        else { status = nil }

        return status.map {
            NormalizedAgentEvent(
                provider: provider,
                sessionID: sessionID,
                status: $0,
                model: modelCandidate(in: payload),
                activity: activityCandidate(in: payload, eventName: loweredEvent, status: $0),
                source: eventSource(for: loweredEvent),
                sessionName: sessionNameCandidate(in: payload),
                estimatedCost: estimatedCostCandidate(in: payload)
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
        if provider == .claude {
            return existing + [["matcher": "", "hooks": [["type": "command", "command": command]]]]
        }
        if provider == .codex {
            return existing + [["hooks": [["type": "command", "command": command]]]]
        }
        return existing + [["command": command]]
    }

    private func contains(command expectedCommand: String, in entry: [String: Any]) -> Bool {
        if entry["command"] as? String == expectedCommand { return true }
        let nestedHooks = entry["hooks"] as? [[String: Any]] ?? []
        return nestedHooks.contains { $0["command"] as? String == expectedCommand }
    }

    private func modelCandidate(in payload: [String: Any]) -> AgentSessionModel? {
        for key in ["model", "model_name", "modelName"] {
            if let value = payload[key] as? String, let model = AgentSessionModel.sanitized(value) {
                return model
            }
        }
        return nil
    }

    private func sessionNameCandidate(in payload: [String: Any]) -> AgentSessionName? {
        for key in ["session_name", "sessionName", "session_title", "sessionTitle"] {
            if let value = payload[key] as? String, let sessionName = AgentSessionName.sanitized(value) {
                return sessionName
            }
        }
        return nil
    }

    private func estimatedCostCandidate(in payload: [String: Any]) -> AgentSessionEstimatedCost? {
        for key in ["estimated_cost", "estimatedCost", "estimated_cost_usd", "estimatedCostUsd", "cost_usd", "costUSD"] {
            guard let value = payload[key], let decimal = decimalValue(from: value) else { continue }
            if let cost = AgentSessionEstimatedCost(usd: decimal) { return cost }
        }
        return nil
    }

    private func decimalValue(from value: Any) -> Decimal? {
        if let decimal = value as? Decimal { return decimal }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.decimalValue
        }
        if let string = value as? String {
            return Decimal(string: string.trimmingCharacters(in: .whitespacesAndNewlines), locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }

    private func activityCandidate(
        in payload: [String: Any],
        eventName: String,
        status: AgentStatus
    ) -> AgentActivity? {
        if status == .failed { return AgentActivity.sanitized("Session failed.") }
        if status == .needsApproval { return AgentActivity.sanitized("Waiting for you…") }
        if eventName.contains("permission") { return AgentActivity.sanitized("Waiting for you…") }
        if eventName == "stop" || eventName.contains("sessionend") { return AgentActivity.sanitized("Done.") }
        if eventName.contains("prompt") || eventName.contains("sessionstart") {
            return AgentActivity.sanitized("Thinking…")
        }
        guard eventName.contains("tool") else { return nil }
        let phase: ToolActivityPhase = eventName.contains("pretool") || eventName.contains("before")
            ? .running
            : .done
        return AgentActivity.sanitized(formatToolActivity(payload: payload, phase: phase))
    }

    private func formatToolActivity(payload: [String: Any], phase: ToolActivityPhase) -> String {
        let toolName = (payload["tool_name"] ?? payload["toolName"]) as? String ?? "tool"
        let input = toolInput(in: payload)
        let lower = toolName.lowercased()
        let past = phase == .done

        if isReadTool(lower) {
            return fileActivity(
                running: "Reading",
                done: "Read",
                fallbackRunning: "Reading file",
                fallbackDone: "Read file",
                input: input,
                past: past
            )
        }
        if isEditTool(lower) {
            return fileActivity(
                running: "Editing",
                done: "Edited",
                fallbackRunning: "Editing file",
                fallbackDone: "Edited file",
                input: input,
                past: past
            )
        }
        if isShellTool(lower) {
            if let command = stringField("command", in: input) {
                let executable = clip(command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? command, to: 20)
                return past ? "Ran \(executable)" : "Running \(executable)"
            }
            return past ? "Ran command" : "Running command"
        }
        if isGrepTool(lower) {
            if let pattern = stringField("pattern", in: input) {
                let text = clip(pattern, to: 28)
                return past ? "Searched \"\(text)\"" : "Searching \"\(text)\""
            }
            return past ? "Searched files" : "Searching files"
        }
        if isGlobTool(lower) {
            if let pattern = stringField("pattern", in: input) {
                let text = clip(pattern, to: 28)
                return past ? "Listed \(text)" : "Listing \(text)"
            }
            return past ? "Listed files" : "Listing files"
        }
        if isWebTool(lower) {
            if let url = stringField("url", in: input), let host = URL(string: url)?.host {
                let text = clip(host, to: 28)
                return past ? "Fetched \(text)" : "Fetching \(text)"
            }
            return past ? "Fetched web" : "Searching web"
        }
        if isTaskTool(lower) {
            if let description = stringField("description", in: input) ?? stringField("subject", in: input) {
                return past ? "Subagent done" : "Spawning \(clip(description, to: 28))"
            }
            return past ? "Subagent done" : "Spawning subagent"
        }
        let name = clip(toolName, to: 28)
        return past ? "Called \(name)" : "Calling \(name)"
    }

    private func toolInput(in payload: [String: Any]) -> [String: Any] {
        if let input = payload["tool_input"] as? [String: Any] { return input }
        if let input = payload["toolInput"] as? [String: Any] { return input }
        return payload
    }

    private func fileActivity(
        running: String,
        done: String,
        fallbackRunning: String,
        fallbackDone: String,
        input: [String: Any],
        past: Bool
    ) -> String {
        if let path = stringField("file_path", in: input) ?? stringField("path", in: input) {
            let name = clip(basename(path), to: 36)
            return past ? "\(done) \(name)" : "\(running) \(name)"
        }
        return past ? fallbackDone : fallbackRunning
    }

    private func stringField(_ key: String, in input: [String: Any]) -> String? {
        input[key] as? String
    }

    private func basename(_ path: String) -> String {
        guard let index = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return path }
        return String(path[path.index(after: index)...])
    }

    private func clip(_ text: String, to maximum: Int) -> String {
        guard text.count > maximum else { return text }
        return "\(text.prefix(maximum - 1))…"
    }

    private func isReadTool(_ tool: String) -> Bool {
        tool == "read" || tool.contains("read_file")
    }

    private func isEditTool(_ tool: String) -> Bool {
        ["edit", "multiedit", "write", "apply_patch"].contains(tool)
    }

    private func isShellTool(_ tool: String) -> Bool {
        tool == "bash" || tool == "shell" || tool.contains("terminal")
    }

    private func isGrepTool(_ tool: String) -> Bool {
        tool == "grep" || tool == "search"
    }

    private func isGlobTool(_ tool: String) -> Bool {
        tool == "glob" || tool == "find" || tool == "list"
    }

    private func isWebTool(_ tool: String) -> Bool {
        tool == "webfetch" || tool == "websearch"
    }

    private func isTaskTool(_ tool: String) -> Bool {
        tool == "task" || tool == "agent"
    }

    private func sessionID(in payload: [String: Any]) -> String? {
        switch provider {
        case .cursor: (payload["conversation_id"] ?? payload["session_id"]) as? String
        case .claude, .codex: payload["session_id"] as? String
        }
    }

    private func eventSource(for eventName: String) -> AgentSessionEventSource {
        if eventName.contains("tool") { return .tool }
        if eventName == "stop" || eventName.contains("sessionend") { return .terminal }
        if eventName.contains("prompt") || eventName.contains("sessionstart") { return .prompt }
        return .unknown
    }

    private func isReadOnlyTool(_ tool: String?) -> Bool {
        guard let tool else { return false }
        let normalized = tool.lowercased()
        return ["read", "search", "grep", "glob", "find", "list"].contains { normalized.contains($0) }
    }

    private func isUserInputTool(_ tool: String?) -> Bool {
        let normalized = tool?.lowercased().filter(\.isLetter) ?? ""
        return normalized.contains("requestuserinput") || normalized.contains("askuser")
    }

    private func isWaitingForUserStatus(_ status: String?) -> Bool {
        let normalized = status?.lowercased().filter(\.isLetter) ?? ""
        return normalized == "waitingforuser" || normalized == "waitingforinput" || normalized == "awaitinguserinput" || normalized == "needsinput"
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

private enum ToolActivityPhase {
    case running
    case done
}
