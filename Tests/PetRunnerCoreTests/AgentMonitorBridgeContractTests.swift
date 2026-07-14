import Foundation
import PetRunnerCore
import Testing

struct AgentMonitorBridgeContractTests {
    @Test func encodesAndValidatesTheSanitizedDisplayNameOnly() throws {
        let displayName = AgentSessionDisplayName.sanitized("Fix\nmonitor", source: .prompt)
        let envelope = AgentMonitorEnvelope(
            token: "token",
            provider: .codex,
            sessionID: "session",
            status: .working,
            displayName: displayName
        )
        let data = try JSONEncoder().encode(envelope)

        let event = try AgentMonitorEnvelope.decode(data, expectedToken: "token")
        #expect(event == NormalizedAgentEvent(provider: .codex, sessionID: "session", status: .working, displayName: displayName))
        #expect(String(data: data, encoding: .utf8)?.contains("Fix monitor") == true)
        #expect(String(data: data, encoding: .utf8)?.contains("file_path") == false)
        #expect(String(data: data, encoding: .utf8)?.contains("command") == false)
    }

    @Test func decodesProtocolOneEnvelopeWhenDisplayNameIsAbsent() throws {
        let data = Data("{\"version\":1,\"token\":\"token\",\"provider\":\"codex\",\"sessionID\":\"session\",\"status\":\"working\"}".utf8)

        let event = try AgentMonitorEnvelope.decode(data, expectedToken: "token")

        #expect(event.displayName == nil)
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
