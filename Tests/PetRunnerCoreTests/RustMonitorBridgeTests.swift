import Foundation
import PetRunnerCore
import Testing

struct RustMonitorBridgeTests {
    @Test func validatesEnvelopeAndMaintainsMruStateThroughRust() {
        let envelope = Data("{\"version\":1,\"token\":\"secret\",\"provider\":\"codex\",\"sessionId\":\"first\",\"status\":\"working\"}".utf8)
        let event = RustMonitor.decodeEnvelope(envelope, token: "secret")
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
