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
}
