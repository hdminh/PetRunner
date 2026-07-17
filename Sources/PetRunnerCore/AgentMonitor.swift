import Foundation

public struct ProviderHeaderColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum AgentProvider: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case cursor

    public var displayLabel: String {
        rawValue.uppercased()
    }

    public var headerColor: ProviderHeaderColor {
        switch self {
        case .claude: ProviderHeaderColor(red: 0.85, green: 0.40, blue: 0.25)
        case .codex: ProviderHeaderColor(red: 0.06, green: 0.64, blue: 0.50)
        case .cursor: ProviderHeaderColor(red: 0.23, green: 0.51, blue: 0.96)
        }
    }
}

/// Optional metadata fields that the Phase 2 bubble can render. Provider and
/// status are always shown and therefore intentionally are not configurable.
public enum MonitorBubbleField: String, CaseIterable, Codable, Sendable {
    case model
    case job
    case sessionName
    case cost

    public var displayLabel: String {
        switch self {
        case .model: "Model"
        case .job: "Job"
        case .sessionName: "Session name"
        case .cost: "Cost"
        }
    }
}

public enum MonitorProviderMigration: Equatable, Sendable {
    case selected(AgentProvider)
    case requiresReconfiguration

    public static func fromLegacyProviders(_ providers: [AgentProvider]) -> Self {
        providers.count == 1 ? .selected(providers[0]) : .requiresReconfiguration
    }
}

public struct MonitorEventFilter: Sendable {
    public let selectedProvider: AgentProvider?

    public init(selectedProvider: AgentProvider?) {
        self.selectedProvider = selectedProvider
    }

    public func accepts(_ event: NormalizedAgentEvent) -> Bool {
        selectedProvider == event.provider
    }
}

public enum AgentStatus: String, CaseIterable, Codable, Sendable {
    case working
    case reviewing
    case needsApproval
    case finished
    case failed

    public var displayText: String {
        switch self {
        case .working: "Working…"
        case .reviewing: "Reviewing…"
        case .needsApproval: "Needs approval"
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }

    public var detailText: String {
        switch self {
        case .working: "WORKING ON TASK"
        case .reviewing: "REVIEWING CHANGES"
        case .needsApproval: "WAITING FOR YOU"
        case .finished: "TURN COMPLETE"
        case .failed: "TURN FAILED"
        }
    }

    public var animation: AnimationState {
        switch self {
        case .working: .running
        case .reviewing: .review
        case .needsApproval: .waiting
        case .finished: .waving
        case .failed: .failed
        }
    }

    public var indicatorTone: AgentStatusTone {
        switch self {
        case .working: .yellow
        case .reviewing: .cyan
        case .needsApproval: .violet
        case .finished: .green
        case .failed: .red
        }
    }
}

public enum AgentStatusTone: String, CaseIterable, Sendable {
    case yellow
    case cyan
    case violet
    case green
    case red
}

public enum AgentSessionScope: Hashable, Sendable {
    case primary
    case subagent(agentID: String)
}

extension AgentSessionScope: Codable {
    private enum CodingKeys: String, CodingKey { case kind, agentID }
    private enum Kind: String, Codable { case primary, subagent }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .primary: self = .primary
        case .subagent:
            self = .subagent(agentID: try container.decode(String.self, forKey: .agentID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .primary:
            try container.encode(Kind.primary, forKey: .kind)
        case let .subagent(agentID):
            try container.encode(Kind.subagent, forKey: .kind)
            try container.encode(agentID, forKey: .agentID)
        }
    }
}

public struct AgentSessionKey: Hashable, Codable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let scope: AgentSessionScope

    public init(provider: AgentProvider, sessionID: String, scope: AgentSessionScope = .primary) {
        self.provider = provider
        self.sessionID = sessionID
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey { case provider, sessionID, scope }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        scope = try container.decodeIfPresent(AgentSessionScope.self, forKey: .scope) ?? .primary
    }
}

public struct AgentSessionModel: Codable, Equatable, Sendable {
    public static let maximumCharacterCount = 18

    public let value: String

    public static func sanitized(_ rawValue: String) -> Self? {
        let supported = rawValue.filter { character in
            PixelGlyphs.rows[character.uppercased().first ?? " "] != nil
        }
        let value = String(supported.prefix(maximumCharacterCount))
        guard !value.isEmpty else { return nil }
        return Self(value: value)
    }

    private init(value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let sanitized = Self.sanitized(value) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Activity is empty")
        }
        self = sanitized
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A short, deterministic summary of one lifecycle or tool event.
///
/// The hook helper derives this from a small allow-list before data crosses the
/// loopback boundary. It is deliberately not a prompt, tool result, or raw
/// hook payload.
public struct AgentActivity: Codable, Equatable, Sendable {
    public static let maximumCharacterCount = 56
    public static let maximumUTF8ByteCount = 240

    public let value: String

    public static func sanitized(_ rawValue: String) -> Self? {
        let withoutControls = String(rawValue.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let collapsed = withoutControls
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        var result = ""
        var byteCount = 0
        var truncated = false
        for character in collapsed {
            let characterValue = String(character)
            let characterBytes = characterValue.lengthOfBytes(using: .utf8)
            if result.count >= maximumCharacterCount || byteCount + characterBytes > maximumUTF8ByteCount {
                truncated = true
                break
            }
            result.append(character)
            byteCount += characterBytes
        }
        guard !result.isEmpty else { return nil }
        if truncated {
            let ellipsisBytes = "…".lengthOfBytes(using: .utf8)
            while !result.isEmpty && (result.count >= maximumCharacterCount || byteCount + ellipsisBytes > maximumUTF8ByteCount) {
                let character = result.removeLast()
                byteCount -= String(character).lengthOfBytes(using: .utf8)
            }
            result.append("…")
        }
        return Self(value: result)
    }

    private init(value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let sanitized = Self.sanitized(value) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Activity is empty")
        }
        self = sanitized
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct AgentSubagentType: Codable, Equatable, Sendable {
    public static let maximumCharacterCount = 32
    public let value: String

    public static func sanitized(_ rawValue: String) -> Self? {
        let value = rawValue
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !value.isEmpty else { return nil }
        return Self(value: String(value.prefix(maximumCharacterCount)))
    }

    private init(value: String) { self.value = value }

    public init(from decoder: Decoder) throws {
        guard let value = Self.sanitized(try decoder.singleValueContainer().decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Subagent type is empty")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct AgentSessionName: Codable, Equatable, Sendable {
    public static let maximumCharacterCount = 48
    public let value: String

    public static func sanitized(_ rawValue: String) -> Self? {
        guard let activity = AgentActivity.sanitized(rawValue) else { return nil }
        return Self(value: String(activity.value.prefix(maximumCharacterCount)))
    }

    private init(value: String) { self.value = value }

    public init(from decoder: Decoder) throws {
        guard let name = Self.sanitized(try decoder.singleValueContainer().decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Session name is empty")
        }
        self = name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct AgentSessionEstimatedCost: Codable, Equatable, Sendable {
    public let usd: Decimal

    public init?(usd: Decimal) {
        guard usd >= 0 else { return nil }
        self.usd = usd
    }

    public var displayText: String {
        if usd > 0, usd < Decimal(string: "0.01")! { return "<$0.01" }
        return String(format: "$%.2f", NSDecimalNumber(decimal: usd).doubleValue)
    }
}

public enum AgentSessionLifecycle: String, Codable, Equatable, Sendable {
    case updated
    case finished
}

/// Identifies the provider hook category that produced an event. This lets the
/// session store reject Cursor worker tool events that cannot be linked to a
/// user-submitted conversation.
public enum AgentSessionEventSource: String, Codable, Equatable, Sendable {
    case unknown
    case prompt
    case tool
    case terminal
    case subagentLifecycle
}

public enum AgentSessionExpiryPolicy {
    public static let primaryGracePeriod: TimeInterval = 5
    public static let subagentGracePeriod: TimeInterval = 2

    public static func gracePeriod(for key: AgentSessionKey) -> TimeInterval {
        switch key.scope {
        case .primary: primaryGracePeriod
        case .subagent: subagentGracePeriod
        }
    }
}

public struct NormalizedAgentEvent: Equatable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let status: AgentStatus
    public let model: AgentSessionModel?
    public let activity: AgentActivity?
    public let scope: AgentSessionScope
    public let agentType: AgentSubagentType?
    public let lifecycle: AgentSessionLifecycle
    public let source: AgentSessionEventSource
    public let sessionName: AgentSessionName?
    public let estimatedCost: AgentSessionEstimatedCost?

    public init(
        provider: AgentProvider,
        sessionID: String,
        status: AgentStatus,
        model: AgentSessionModel? = nil,
        activity: AgentActivity? = nil,
        scope: AgentSessionScope = .primary,
        agentType: AgentSubagentType? = nil,
        lifecycle: AgentSessionLifecycle = .updated,
        source: AgentSessionEventSource = .unknown,
        sessionName: AgentSessionName? = nil,
        estimatedCost: AgentSessionEstimatedCost? = nil
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.status = status
        self.model = model
        self.activity = activity
        self.scope = scope
        self.agentType = agentType
        self.lifecycle = lifecycle
        self.source = source
        self.sessionName = sessionName
        self.estimatedCost = estimatedCost
    }

    public var key: AgentSessionKey {
        AgentSessionKey(provider: provider, sessionID: sessionID, scope: scope)
    }
}

public struct AgentSessionSnapshot: Equatable, Sendable {
    public let key: AgentSessionKey
    public let status: AgentStatus
    public let model: AgentSessionModel?
    public let activity: AgentActivity?
    public let agentType: AgentSubagentType?
    public let sessionName: AgentSessionName?
    public let estimatedCost: AgentSessionEstimatedCost?

    public init(
        key: AgentSessionKey,
        status: AgentStatus,
        model: AgentSessionModel? = nil,
        activity: AgentActivity? = nil,
        agentType: AgentSubagentType? = nil,
        sessionName: AgentSessionName? = nil,
        estimatedCost: AgentSessionEstimatedCost? = nil
    ) {
        self.key = key
        self.status = status
        self.model = model
        self.activity = activity
        self.agentType = agentType
        self.sessionName = sessionName
        self.estimatedCost = estimatedCost
    }

    public var provider: AgentProvider { key.provider }
    public var sessionID: String { key.sessionID }
    public var displayText: String { status.displayText }
    public var detailText: String { activity?.value ?? status.detailText }
    public var animation: AnimationState { status.animation }
    public var indicatorTone: AgentStatusTone { status.indicatorTone }
}

public struct AgentSessionStore: Sendable {
    public private(set) var entries: [AgentSessionSnapshot] = []
    public private(set) var selectedIndex = 0

    public init() {}

    public var selected: AgentSessionSnapshot? {
        guard entries.indices.contains(selectedIndex) else { return nil }
        return entries[selectedIndex]
    }

    /// Cursor does not identify tool events emitted by subagents. Only tool
    /// updates for a primary session first observed from a prompt are safe to
    /// display; otherwise a completed worker can leave an orphaned bubble.
    public func accepts(_ event: NormalizedAgentEvent) -> Bool {
        guard event.provider == .cursor, event.source == .tool else { return true }
        return entries.contains { $0.key == event.key && $0.key.scope == .primary }
    }

    @discardableResult
    public mutating func upsert(_ event: NormalizedAgentEvent) -> Bool {
        let selectedKey = selected?.key
        let existingIndex = entries.firstIndex { $0.key == event.key }
        let existing = existingIndex.map { entries[$0] }
        let model = event.model ?? existing?.model
        let activity = event.activity ?? existing?.activity
        let agentType = event.agentType ?? existing?.agentType
        let sessionName = event.sessionName ?? existing?.sessionName
        let estimatedCost = event.estimatedCost ?? existing?.estimatedCost
        let snapshot = AgentSessionSnapshot(
            key: event.key,
            status: event.status,
            model: model,
            activity: activity,
            agentType: agentType,
            sessionName: sessionName,
            estimatedCost: estimatedCost
        )
        if let existingIndex {
            guard entries[existingIndex] != snapshot else { return false }
            entries[existingIndex] = snapshot
        } else {
            entries.insert(snapshot, at: 0)
        }
        restoreSelection(for: selectedKey)
        return true
    }

    public mutating func selectPrevious() {
        selectedIndex = max(0, selectedIndex - 1)
    }

    public mutating func selectNext() {
        selectedIndex = min(max(0, entries.count - 1), selectedIndex + 1)
    }

    /// Selects a retained session without changing its most-recent-first order.
    @discardableResult
    public mutating func select(at index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        selectedIndex = index
        return true
    }

    public mutating func removeAll() {
        entries.removeAll()
        selectedIndex = 0
    }

    @discardableResult
    public mutating func remove(_ key: AgentSessionKey) -> Bool {
        let selectedKey = selected?.key
        let originalCount = entries.count
        entries.removeAll { $0.key == key }
        guard entries.count != originalCount else { return false }
        restoreSelection(for: selectedKey)
        return true
    }

    private mutating func restoreSelection(for key: AgentSessionKey?) {
        if let key, let preservedIndex = entries.firstIndex(where: { $0.key == key }) {
            selectedIndex = preservedIndex
        } else {
            selectedIndex = min(selectedIndex, max(0, entries.count - 1))
        }
    }

}
