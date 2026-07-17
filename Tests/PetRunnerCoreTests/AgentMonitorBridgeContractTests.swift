import Foundation
import PetRunnerCore
import Testing

struct AgentMonitorBridgeContractTests {
    @Test func encodesAndValidatesOnlyDerivedActivityMetadata() throws {
        let model = AgentSessionModel.sanitized("gpt-5.2-codex")
        let activity = AgentActivity.sanitized("Reading server.ts")
        let envelope = AgentMonitorEnvelope(
            token: "token",
            provider: .codex,
            sessionID: "session",
            status: .working,
            model: model,
            activity: activity
        )
        let data = try JSONEncoder().encode(envelope)

        let event = try AgentMonitorEnvelope.decode(data, expectedToken: "token")
        #expect(event == NormalizedAgentEvent(provider: .codex, sessionID: "session", status: .working, model: model, activity: activity))
        #expect(String(data: data, encoding: .utf8)?.contains("gpt-5.2-codex") == true)
        #expect(String(data: data, encoding: .utf8)?.contains("Reading server.ts") == true)
        #expect(String(data: data, encoding: .utf8)?.contains("file_path") == false)
        #expect(String(data: data, encoding: .utf8)?.contains("command") == false)
    }

    @Test func decodesProtocolOneEnvelopeWhenOptionalActivityIsAbsent() throws {
        let data = Data("{\"version\":1,\"token\":\"token\",\"provider\":\"codex\",\"sessionID\":\"session\",\"status\":\"working\"}".utf8)

        let event = try AgentMonitorEnvelope.decode(data, expectedToken: "token")

        #expect(event.activity == nil)
        #expect(event.scope == .primary)
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
            try AgentMonitorEnvelope(version: 4, token: "token", provider: .cursor, sessionID: "session", status: .finished).validated(expectedToken: "token")
        }
        #expect(throws: AgentMonitorBridgeError.oversizedEnvelope) {
            try AgentMonitorEnvelope.decode(Data(repeating: 0, count: AgentMonitorEnvelope.maximumBytes + 1), expectedToken: "token")
        }
    }

    @Test func roundTripsBoundedDisplayMetadataInProtocolThree() throws {
        let envelope = AgentMonitorEnvelope(
            token: "token",
            provider: .claude,
            sessionID: "session",
            status: .working,
            sessionName: AgentSessionName.sanitized("Thought bubble"),
            estimatedCost: AgentSessionEstimatedCost(usd: Decimal(string: "1.25")!)
        )
        let event = try AgentMonitorEnvelope.decode(JSONEncoder().encode(envelope), expectedToken: "token")
        #expect(event.sessionName?.value == "Thought bubble")
        #expect(event.estimatedCost?.displayText == "$1.25")
    }

    @Test func roundTripsScopedLifecycleFieldsInProtocolTwo() throws {
        let envelope = AgentMonitorEnvelope(
            token: "token",
            provider: .claude,
            sessionID: "root",
            status: .finished,
            scope: .subagent(agentID: "child"),
            agentType: AgentSubagentType.sanitized("Explore"),
            lifecycle: .finished
        )

        let event = try AgentMonitorEnvelope.decode(JSONEncoder().encode(envelope), expectedToken: "token")
        #expect(event.key.scope == .subagent(agentID: "child"))
        #expect(event.agentType?.value == "Explore")
        #expect(event.lifecycle == .finished)
    }
}
