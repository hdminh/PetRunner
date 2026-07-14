import Foundation
import PetRunnerCore
import Testing

struct AgentMonitorBridgeContractTests {
    @Test func encodesAndValidatesOnlyTheNormalizedEnvelope() throws {
        let envelope = AgentMonitorEnvelope(token: "token", provider: .codex, sessionID: "session", status: .working)
        let data = try JSONEncoder().encode(envelope)

        let event = try AgentMonitorEnvelope.decode(data, expectedToken: "token")
        #expect(event == NormalizedAgentEvent(provider: .codex, sessionID: "session", status: .working))
        #expect(String(data: data, encoding: .utf8)?.contains("prompt") == false)
        #expect(String(data: data, encoding: .utf8)?.contains("sessionLabel") == false)
    }

    @Test func rejectsInvalidEnvelopeInputs() throws {
        let valid = AgentMonitorEnvelope(token: "token", provider: .cursor, sessionID: "session", status: .finished)
        let data = try JSONEncoder().encode(valid)
        #expect(throws: AgentMonitorBridgeError.invalidToken) {
            try AgentMonitorEnvelope.decode(data, expectedToken: "wrong")
        }
        #expect(throws: AgentMonitorBridgeError.invalidSession) {
            try AgentMonitorEnvelope(token: "token", provider: .cursor, sessionID: " ", status: .finished).validated(expectedToken: "token")
        }
        #expect(throws: AgentMonitorBridgeError.unsupportedVersion) {
            try AgentMonitorEnvelope(version: 2, token: "token", provider: .cursor, sessionID: "session", status: .finished).validated(expectedToken: "token")
        }
        #expect(throws: AgentMonitorBridgeError.oversizedEnvelope) {
            try AgentMonitorEnvelope.decode(Data(repeating: 0, count: AgentMonitorEnvelope.maximumBytes + 1), expectedToken: "token")
        }
    }
}
