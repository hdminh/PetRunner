import Foundation

public enum AgentMonitorBridgeError: Error, Equatable, Sendable {
    case malformedEnvelope
    case unsupportedVersion
    case invalidToken
    case invalidSession
    case oversizedEnvelope
}

public struct AgentMonitorEnvelope: Codable, Equatable, Sendable {
    public static let protocolVersion = 1
    public static let maximumBytes = 4_096

    public let version: Int
    public let token: String
    public let provider: AgentProvider
    public let sessionID: String
    public let status: AgentStatus
    public let displayName: AgentSessionDisplayName?

    public init(
        version: Int = Self.protocolVersion,
        token: String,
        provider: AgentProvider,
        sessionID: String,
        status: AgentStatus,
        displayName: AgentSessionDisplayName? = nil
    ) {
        self.version = version
        self.token = token
        self.provider = provider
        self.sessionID = sessionID
        self.status = status
        self.displayName = displayName
    }

    public func validated(expectedToken: String) throws -> NormalizedAgentEvent {
        guard version == Self.protocolVersion else { throw AgentMonitorBridgeError.unsupportedVersion }
        guard token == expectedToken, !token.isEmpty else { throw AgentMonitorBridgeError.invalidToken }
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentMonitorBridgeError.invalidSession }
        return NormalizedAgentEvent(provider: provider, sessionID: sessionID, status: status, displayName: displayName)
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
