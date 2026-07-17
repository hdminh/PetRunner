import Foundation

public enum AgentMonitorBridgeError: Error, Equatable, Sendable {
    case malformedEnvelope
    case unsupportedVersion
    case invalidToken
    case invalidSession
    case oversizedEnvelope
}

public struct AgentMonitorEnvelope: Codable, Equatable, Sendable {
    public static let protocolVersion = 3
    public static let maximumBytes = 4_096

    public let version: Int
    public let token: String
    public let provider: AgentProvider
    public let sessionID: String
    public let status: AgentStatus
    public let model: AgentSessionModel?
    public let activity: AgentActivity?
    public let scope: AgentSessionScope?
    public let agentType: AgentSubagentType?
    public let lifecycle: AgentSessionLifecycle?
    public let sessionName: AgentSessionName?
    public let estimatedCost: AgentSessionEstimatedCost?

    public init(
        version: Int = Self.protocolVersion,
        token: String,
        provider: AgentProvider,
        sessionID: String,
        status: AgentStatus,
        model: AgentSessionModel? = nil,
        activity: AgentActivity? = nil,
        scope: AgentSessionScope? = nil,
        agentType: AgentSubagentType? = nil,
        lifecycle: AgentSessionLifecycle? = nil,
        sessionName: AgentSessionName? = nil,
        estimatedCost: AgentSessionEstimatedCost? = nil
    ) {
        self.version = version
        self.token = token
        self.provider = provider
        self.sessionID = sessionID
        self.status = status
        self.model = model
        self.activity = activity
        self.scope = scope
        self.agentType = agentType
        self.lifecycle = lifecycle
        self.sessionName = sessionName
        self.estimatedCost = estimatedCost
    }

    public func validated(expectedToken: String) throws -> NormalizedAgentEvent {
        guard (1...Self.protocolVersion).contains(version) else { throw AgentMonitorBridgeError.unsupportedVersion }
        guard token == expectedToken, !token.isEmpty else { throw AgentMonitorBridgeError.invalidToken }
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentMonitorBridgeError.invalidSession }
        return NormalizedAgentEvent(
            provider: provider,
            sessionID: sessionID,
            status: status,
            model: model,
            activity: activity,
            scope: scope ?? .primary,
            agentType: agentType,
            lifecycle: lifecycle ?? .updated,
            sessionName: sessionName,
            estimatedCost: estimatedCost
        )
    }

    public static func decode(_ data: Data, expectedToken: String) throws -> NormalizedAgentEvent {
        guard data.count <= maximumBytes else { throw AgentMonitorBridgeError.oversizedEnvelope }
        guard let envelope = try? JSONDecoder().decode(Self.self, from: data) else { throw AgentMonitorBridgeError.malformedEnvelope }
        return try envelope.validated(expectedToken: expectedToken)
    }
}

public struct AgentMonitorRuntimeDescriptor: Codable, Equatable, Sendable {
    public let port: UInt16
    public let token: String

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }
}
