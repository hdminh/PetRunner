import Foundation
import PetRunnerCore
import Testing

struct RustMonitorBridgeTests {
    @Test func validatesEnvelopeAndMaintainsMruStateThroughRust() {
        let envelope = AgentMonitorEnvelope(
            token: "secret",
            provider: .codex,
            sessionID: "first",
            status: .working
        )
        let event = RustMonitor.decodeEnvelope(try! JSONEncoder().encode(envelope), token: "secret")
        #expect(event?.sessionID == "first")
        #expect(event?.status == .working)

        let store = RustAgentSessionStore()
        store.upsert(event!)
        store.upsert(NormalizedAgentEvent(provider: .claude, sessionID: "second", status: .reviewing))
        store.selectNext()

        #expect(store.entries.map(\.sessionID) == ["second", "first"])
        #expect(store.selected?.sessionID == "first")
    }

    @Test func preservesSelectedSessionAcrossRustUpdatesAndNewSessions() {
        let store = RustAgentSessionStore()
        store.upsert(NormalizedAgentEvent(provider: .codex, sessionID: "oldest", status: .working))
        store.upsert(NormalizedAgentEvent(provider: .claude, sessionID: "selected", status: .reviewing))
        store.upsert(NormalizedAgentEvent(provider: .cursor, sessionID: "newest", status: .needsApproval))
        store.selectPrevious()

        store.upsert(NormalizedAgentEvent(provider: .claude, sessionID: "selected", status: .finished))

        #expect(store.entries.map(\.sessionID) == ["newest", "selected", "oldest"])
        #expect(store.selected?.sessionID == "selected")
        #expect(store.selected?.status == .finished)
        #expect(store.selectedIndex == 1)

        store.upsert(NormalizedAgentEvent(provider: .codex, sessionID: "incoming", status: .working))

        #expect(store.entries.map(\.sessionID) == ["incoming", "newest", "selected", "oldest"])
        #expect(store.selected?.sessionID == "selected")
        #expect(store.selectedIndex == 2)
    }

    @Test func preservesTheCapturedCodexPromptTitleAcrossToolEvents() {
        let promptPayload = Data(
            #"{"cwd":"/Users/minhc/Documents/PetRunner","hook_event_name":"UserPromptSubmit","model":"gpt-5.6-terra","permission_mode":"default","prompt":"PetRunner monitor capture validation.","session_id":"codex-captured-session","transcript_path":null,"turn_id":"codex-captured-turn"}"#.utf8
        )
        let toolPayload = Data(
            #"{"cwd":"/Users/minhc/Documents/PetRunner","hook_event_name":"PreToolUse","model":"gpt-5.6-terra","permission_mode":"default","session_id":"codex-captured-session","tool_input":{"command":"pwd"},"tool_name":"exec","tool_use_id":"toolu-captured","transcript_path":null,"turn_id":"codex-captured-turn"}"#.utf8
        )

        let prompt = RustMonitor.normalize(provider: .codex, payload: promptPayload, event: "UserPromptSubmit")
        let tool = RustMonitor.normalize(provider: .codex, payload: toolPayload, event: "PreToolUse")

        #expect(prompt?.sessionID == "codex-captured-session")
        #expect(prompt?.displayName?.value == "PetRunner monitor capture validation.")
        #expect(tool?.sessionID == prompt?.sessionID)
        #expect(tool?.displayName == nil)

        let store = RustAgentSessionStore()
        store.upsert(prompt!)
        store.upsert(tool!)

        #expect(store.selected?.detailText == "PetRunner monitor capture validation.")
    }
}
