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

    @Test func normalizesOnlySafeFields() {
        let configuration = ProviderHookConfiguration(provider: .cursor)
        let payload: [String: Any] = [
            "conversation_id": "safe-session",
            "tool_name": "Read",
            "prompt": "secret prompt",
            "command": "rm -rf /",
            "file_path": "/secret/file",
        ]
        let event = configuration.normalize(payload: payload, eventName: "preToolUse")

        #expect(event == NormalizedAgentEvent(provider: .cursor, sessionID: "safe-session", status: .reviewing))
    }

    @Test func mapsProviderEventsAndNeutralOutputRequirements() {
        let claude = ProviderHookConfiguration(provider: .claude)
        let codex = ProviderHookConfiguration(provider: .codex)
        let cursor = ProviderHookConfiguration(provider: .cursor)

        #expect(claude.normalize(payload: ["session_id": "a"], eventName: "PermissionRequest")?.status == .needsApproval)
        #expect(codex.normalize(payload: ["session_id": "a"], eventName: "Stop")?.status == .finished)
        #expect(cursor.normalize(payload: ["conversation_id": "a", "status": "error"], eventName: "stop")?.status == .failed)
        #expect(cursor.normalize(payload: ["conversation_id": "a"], eventName: "permissionRequest") == nil)
        #expect(!claude.requiresNeutralJSONOutput)
        #expect(!codex.requiresNeutralJSONOutput)
        #expect(cursor.requiresNeutralJSONOutput)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func command(in entry: [String: Any]) -> String? {
        (entry["command"] as? String) ?? ((entry["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
}
