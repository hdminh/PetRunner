import Foundation
import PetRunnerCore
import Testing

struct ProviderHookConfigurationTests {
    @Test(arguments: AgentProvider.allCases) func installIsIdempotentAndOwned(provider: AgentProvider) throws {
        let configuration = ProviderHookConfiguration(provider: provider)
        let once = try configuration.install(into: Data("{}".utf8), executablePath: "/Applications/Pet Runner.app/Contents/MacOS/PetRunner")
        let twice = try configuration.install(into: once, executablePath: "/Applications/Pet Runner.app/Contents/MacOS/PetRunner")

        #expect(once == twice)
        let root = try json(once)
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(configuration.events))
        for event in configuration.events {
            let entry = try #require((hooks[event] as? [[String: Any]])?.first)
            let hookCommand = try #require(command(in: entry))
            #expect(hookCommand.contains(ProviderHookConfiguration.ownershipMarker))
            #expect(hookCommand.contains("Pet Runner.app"))
        }
    }

    @Test func preservesThirdPartyHooksAndRemovesOnlyOwnedEntries() throws {
        let configuration = ProviderHookConfiguration(provider: .codex)
        let original = Data("{\"hooks\":{\"preToolUse\":[{\"command\":\"other-one\"},{\"command\":\"other-two\"}]},\"other\":true}".utf8)
        let installed = try configuration.install(into: original, executablePath: "/tmp/pet")
        let removed = try configuration.remove(from: installed)
        let root = try json(removed)
        let hooks = try #require(root["hooks"] as? [String: Any])
        let entries = try #require(hooks["preToolUse"] as? [[String: Any]])
        #expect(entries.compactMap { $0["command"] as? String } == ["other-one", "other-two"])
        #expect(root["other"] as? Bool == true)
    }

    @Test func removesOnlyNestedClaudeOwnedHooks() throws {
        let configuration = ProviderHookConfiguration(provider: .claude)
        let original = Data("{\"hooks\":{\"Stop\":[{\"matcher\":\"other\",\"hooks\":[{\"type\":\"command\",\"command\":\"other-command\"}]}]}}".utf8)
        let installed = try configuration.install(into: original, executablePath: "/tmp/pet")
        let removed = try configuration.remove(from: installed)
        let root = try json(removed)
        let hooks = try #require(root["hooks"] as? [String: Any])
        let stopEntries = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stopEntries.count == 1)
        #expect(command(in: stopEntries[0]) == "other-command")
    }

    @Test func codexUsesDocumentedMatcherGroupShape() throws {
        let configuration = ProviderHookConfiguration(provider: .codex)
        let installed = try configuration.install(into: Data("{}".utf8), executablePath: "/tmp/pet")
        let root = try json(installed)
        let hooks = try #require(root["hooks"] as? [String: Any])
        let entry = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
        let nested = try #require(entry["hooks"] as? [[String: Any]])
        #expect(nested.first?["type"] as? String == "command")
        #expect(command(in: entry)?.contains(ProviderHookConfiguration.ownershipMarker) == true)
        #expect(hooks["PostToolUseFailure"] == nil)
        #expect(hooks["StopFailure"] == nil)
    }

    @Test func claudeUsesAnExplicitEmptyMatcherForCursorCompatibility() throws {
        let configuration = ProviderHookConfiguration(provider: .claude)
        let installed = try configuration.install(into: Data("{}".utf8), executablePath: "/tmp/pet")
        let root = try json(installed)
        let hooks = try #require(root["hooks"] as? [String: Any])
        let entry = try #require((hooks["SessionStart"] as? [[String: Any]])?.first)

        #expect(entry["matcher"] as? String == "")
    }

    @Test func cursorAddsVersionOneAndUsesDocumentedEvents() throws {
        let configuration = ProviderHookConfiguration(provider: .cursor)
        let installed = try configuration.install(into: Data("{}".utf8), executablePath: "/tmp/pet")
        let root = try json(installed)
        let hooks = try #require(root["hooks"] as? [String: Any])

        #expect(root["version"] as? Int == 1)
        #expect(Set(hooks.keys) == Set(["beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop", "sessionEnd", "subagentStart", "subagentStop"]))
    }

    @Test func installingPurgesStaleOwnedEventsWithoutRemovingThirdPartyHooks() throws {
        let configuration = ProviderHookConfiguration(provider: .codex)
        let stale = configuration.command(executablePath: "/tmp/old", event: "StopFailure")
        let original = Data("{\"hooks\":{\"StopFailure\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(stale)\"}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"other-command\"}]}]}}".utf8)

        let installed = try configuration.install(into: original, executablePath: "/tmp/pet")
        let root = try json(installed)
        let hooks = try #require(root["hooks"] as? [String: Any])

        #expect(hooks["StopFailure"] == nil)
        let stopEntries = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stopEntries.contains { command(in: $0) == "other-command" })
    }

    @Test func refusesMalformedAndUnsupportedRoots() {
        let configuration = ProviderHookConfiguration(provider: .claude)
        #expect(throws: ProviderHookError.malformedJSON) {
            try configuration.install(into: Data("not json".utf8), executablePath: "/tmp/pet")
        }
        #expect(throws: ProviderHookError.unsupportedRoot) {
            try configuration.install(into: Data("[]".utf8), executablePath: "/tmp/pet")
        }
    }

    @Test func normalizesOnlyDerivedActivityFields() {
        let configuration = ProviderHookConfiguration(provider: .cursor)
        let payload: [String: Any] = [
            "conversation_id": "safe-session",
            "tool_name": "Read",
            "model_name": "gpt-5.2-codex",
            "prompt": "secret prompt",
            "command": "rm -rf /",
            "file_path": "/secret/file",
        ]
        let event = configuration.normalize(payload: payload, eventName: "preToolUse")

        #expect(event == NormalizedAgentEvent(
            provider: .cursor,
            sessionID: "safe-session",
            status: .reviewing,
            model: AgentSessionModel.sanitized("gpt-5.2-codex"),
            activity: AgentActivity.sanitized("Reading file"),
            source: .tool
        ))
    }

    @Test func normalizesClaudeSubagentLifecycleWithoutForwardingMessages() {
        let configuration = ProviderHookConfiguration(provider: .claude)
        #expect(configuration.events.contains("SubagentStart"))
        #expect(configuration.events.contains("SubagentStop"))

        let start = configuration.normalize(
            payload: [
                "session_id": "root",
                "agent_id": "child-a",
                "agent_type": "Explore",
                "model": "claude-sonnet-4-5",
                "prompt": "do not retain",
            ],
            eventName: "SubagentStart"
        )
        let stop = configuration.normalize(
            payload: [
                "session_id": "root",
                "agent_id": "child-a",
                "agent_type": "Explore",
                "last_assistant_message": "do not retain",
            ],
            eventName: "SubagentStop"
        )

        #expect(start?.key.scope == .subagent(agentID: "child-a"))
        #expect(start?.agentType?.value == "Explore")
        #expect(start?.status == .working)
        #expect(stop?.key.scope == .subagent(agentID: "child-a"))
        #expect(stop?.status == .finished)
        #expect(stop?.lifecycle == .finished)
        #expect(stop?.activity?.value.contains("retain") == false)
    }

    @Test func normalizesCursorSubagentLifecycleWithoutForwardingTaskData() {
        let configuration = ProviderHookConfiguration(provider: .cursor)
        #expect(configuration.events.contains("subagentStart"))
        #expect(configuration.events.contains("subagentStop"))

        let start = configuration.normalize(
            payload: [
                "conversation_id": "root",
                "subagent_id": "child-a",
                "subagent_type": "general-purpose",
                "model": "gpt-5.3-codex",
                "task": "do not retain",
            ],
            eventName: "subagentStart"
        )
        let stop = configuration.normalize(
            payload: [
                "conversation_id": "root",
                "subagent_id": "child-a",
                "subagent_type": "general-purpose",
                "task": "do not retain",
            ],
            eventName: "subagentStop"
        )

        #expect(start?.key == AgentSessionKey(provider: .cursor, sessionID: "root", scope: .subagent(agentID: "child-a")))
        #expect(start?.agentType?.value == "general-purpose")
        #expect(start?.status == .working)
        #expect(start?.source == .subagentLifecycle)
        #expect(stop?.key == start?.key)
        #expect(stop?.status == .finished)
        #expect(stop?.lifecycle == .finished)
        #expect(stop?.source == .subagentLifecycle)
        #expect(stop?.activity?.value.contains("retain") == false)
    }

    @Test func capturesModelFromSupportedPayloadKeys() {
        let claude = ProviderHookConfiguration(provider: .claude)
        let codex = ProviderHookConfiguration(provider: .codex)
        let cursor = ProviderHookConfiguration(provider: .cursor)

        #expect(claude.normalize(payload: ["session_id": "a", "model": "claude-sonnet-4-5"], eventName: "SessionStart")?.model?.value == "claude-sonnet-4-5")
        #expect(codex.normalize(payload: ["session_id": "b", "model_name": "gpt-5.2-codex"], eventName: "SessionStart")?.model?.value == "gpt-5.2-codex")
        #expect(cursor.normalize(payload: ["conversation_id": "c", "modelName": "cursor-small"], eventName: "sessionStart") == nil)
    }

    @Test func capturesSafeSessionMetadataWithoutRetainingPromptText() throws {
        let configuration = ProviderHookConfiguration(provider: .codex)
        let event = configuration.normalize(
            payload: [
                "session_id": "safe-session",
                "session_title": "Bubble redesign",
                "estimatedCostUsd": "0.25",
                "prompt": "do not retain",
            ],
            eventName: "SessionStart"
        )

        let normalized = try #require(event)
        var store = AgentSessionStore()
        store.upsert(normalized)

        #expect(normalized.sessionName?.value == "Bubble redesign")
        #expect(normalized.estimatedCost?.displayText == "$0.25")
        #expect(normalized.activity?.value.contains("retain") == false)
        #expect(store.selected?.sessionName?.value == "Bubble redesign")
        #expect(store.selected?.estimatedCost?.displayText == "$0.25")
    }

    @Test func rejectsInvalidCostMetadata() {
        let configuration = ProviderHookConfiguration(provider: .codex)
        let event = configuration.normalize(
            payload: ["session_id": "safe-session", "estimated_cost": "-1"],
            eventName: "SessionStart"
        )

        #expect(event?.estimatedCost == nil)
    }

    @Test func formatsLifecycleActivitiesWithoutForwardingPromptText() {
        let claude = ProviderHookConfiguration(provider: .claude)
        let codex = ProviderHookConfiguration(provider: .codex)
        let cursor = ProviderHookConfiguration(provider: .cursor)

        #expect(claude.normalize(payload: ["session_id": "a", "prompt": "Claude secret"], eventName: "UserPromptSubmit")?.activity?.value == "Thinking…")
        #expect(codex.normalize(payload: ["session_id": "b", "prompt": "Codex secret"], eventName: "UserPromptSubmit")?.activity?.value == "Thinking…")
        #expect(cursor.normalize(payload: ["conversation_id": "c", "prompt": "Cursor secret"], eventName: "beforeSubmitPrompt")?.activity?.value == "Thinking…")
        #expect(cursor.normalize(payload: ["conversation_id": "c"], eventName: "sessionStart") == nil)
    }

    @Test func formatsNestedAndFlattenedToolActivities() {
        let codex = ProviderHookConfiguration(provider: .codex)
        let claude = ProviderHookConfiguration(provider: .claude)
        let cursor = ProviderHookConfiguration(provider: .cursor)

        #expect(codex.normalize(
            payload: ["session_id": "a", "tool_name": "Read", "tool_input": ["file_path": "/work/Sources/server.ts"]],
            eventName: "PreToolUse"
        )?.activity?.value == "Reading server.ts")
        #expect(claude.normalize(
            payload: ["session_id": "b", "tool_name": "Bash", "tool_input": ["command": "swift test --filter Monitor"]],
            eventName: "PostToolUse"
        )?.activity?.value == "Ran swift")
        #expect(cursor.normalize(
            payload: ["conversation_id": "c", "tool_name": "Grep", "pattern": "FIXME"],
            eventName: "preToolUse"
        )?.activity?.value == "Searching \"FIXME\"")
    }

    @Test func formatsWebTaskAndUnknownActivitiesWithBoundedText() {
        let configuration = ProviderHookConfiguration(provider: .codex)

        #expect(configuration.normalize(
            payload: ["session_id": "a", "tool_name": "WebFetch", "tool_input": ["url": "https://docs.openai.com/path"]],
            eventName: "PreToolUse"
        )?.activity?.value == "Fetching docs.openai.com")
        #expect(configuration.normalize(
            payload: ["session_id": "a", "tool_name": "Task", "tool_input": ["description": "inspect hook payloads"]],
            eventName: "PreToolUse"
        )?.activity?.value == "Spawning inspect hook payloads")
        #expect(configuration.normalize(
            payload: ["session_id": "a", "tool_name": "mcp__custom__do_thing"],
            eventName: "PostToolUse"
        )?.activity?.value == "Called mcp__custom__do_thing")
        let long = configuration.normalize(
            payload: ["session_id": "a", "tool_name": "Read", "tool_input": ["file_path": "/work/" + String(repeating: "x", count: 120) + ".swift"]],
            eventName: "PreToolUse"
        )
        #expect(long?.activity?.value.count ?? 0 <= AgentActivity.maximumCharacterCount)
        #expect(long?.activity?.value.hasSuffix("…") == true)
    }

    @Test func mapsProviderEventsAndNeutralOutputRequirements() {
        let claude = ProviderHookConfiguration(provider: .claude)
        let codex = ProviderHookConfiguration(provider: .codex)
        let cursor = ProviderHookConfiguration(provider: .cursor)

        #expect(claude.normalize(payload: ["session_id": "a"], eventName: "PermissionRequest")?.status == .needsApproval)
        #expect(claude.normalize(payload: ["session_id": "a"], eventName: "PermissionRequest")?.activity?.value == "Waiting for you…")
        #expect(codex.normalize(payload: ["session_id": "a"], eventName: "Stop")?.status == .finished)
        #expect(codex.normalize(payload: ["session_id": "a"], eventName: "Stop")?.activity?.value == "Done.")
        #expect(cursor.normalize(payload: ["conversation_id": "a", "status": "error"], eventName: "stop")?.status == .failed)
        #expect(cursor.normalize(payload: ["conversation_id": "a", "status": "error"], eventName: "stop")?.activity?.value == "Session failed.")
        #expect(cursor.normalize(payload: ["conversation_id": "a"], eventName: "permissionRequest") == nil)
        #expect(!claude.requiresNeutralJSONOutput)
        #expect(!codex.requiresNeutralJSONOutput)
        #expect(cursor.requiresNeutralJSONOutput)
    }

    @Test func mapsUserInputToolsToWaitingForYou() {
        let configuration = ProviderHookConfiguration(provider: .codex)
        let waiting = configuration.normalize(
            payload: ["session_id": "session", "tool_name": "request_user_input"],
            eventName: "PreToolUse"
        )
        let resumed = configuration.normalize(
            payload: ["session_id": "session", "tool_name": "request_user_input"],
            eventName: "PostToolUse"
        )

        #expect(waiting?.status == .needsApproval)
        #expect(waiting?.activity?.value == "Waiting for you…")
        #expect(resumed?.status == .working)
    }

    @Test func mapsCamelCaseAndWaitingStatusToWaitingForYou() {
        let configuration = ProviderHookConfiguration(provider: .codex)
        let camelCaseTool = configuration.normalize(
            payload: ["session_id": "tool-session", "toolName": "RequestUserInput"],
            eventName: "PreToolUse"
        )
        let waitingStatus = configuration.normalize(
            payload: ["session_id": "status-session", "status": "waiting_for_user"],
            eventName: "SessionStart"
        )

        #expect(camelCaseTool?.status == .needsApproval)
        #expect(waitingStatus?.status == .needsApproval)
        #expect(waitingStatus?.activity?.value == "Waiting for you…")
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func command(in entry: [String: Any]) -> String? {
        (entry["command"] as? String) ?? ((entry["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
}
