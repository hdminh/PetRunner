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
}
