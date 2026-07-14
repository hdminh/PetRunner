import Foundation

public enum AgentProvider: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case cursor

    public var displayLabel: String {
        rawValue.uppercased()
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

public struct AgentSessionKey: Hashable, Codable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String

    public init(provider: AgentProvider, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }
}

public enum AgentSessionDisplayNameSource: Int, Codable, Sendable, Comparable {
    case prompt
    case nativeProvider

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct AgentSessionDisplayName: Codable, Equatable, Sendable {
    public static let maximumCharacterCount = 96
    public static let maximumUTF8ByteCount = 384

    public let value: String
    public let source: AgentSessionDisplayNameSource

    public static func sanitized(_ rawValue: String, source: AgentSessionDisplayNameSource) -> Self? {
        let collapsed = rawValue
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        var result = ""
        var byteCount = 0
        for character in collapsed {
            guard result.count < maximumCharacterCount else { break }
            let characterValue = String(character)
            let characterBytes = characterValue.lengthOfBytes(using: .utf8)
            guard byteCount + characterBytes <= maximumUTF8ByteCount else { break }
            result.append(character)
            byteCount += characterBytes
        }
        guard !result.isEmpty else { return nil }
        return Self(value: result, source: source)
    }

    private init(value: String, source: AgentSessionDisplayNameSource) {
        self.value = value
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        let source = try container.decode(AgentSessionDisplayNameSource.self, forKey: .source)
        guard let sanitized = Self.sanitized(value, source: source) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Display name is empty")
        }
        self = sanitized
    }
}

public struct NormalizedAgentEvent: Equatable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let status: AgentStatus
    public let displayName: AgentSessionDisplayName?

    public init(
        provider: AgentProvider,
        sessionID: String,
        status: AgentStatus,
        displayName: AgentSessionDisplayName? = nil
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.status = status
        self.displayName = displayName
    }

    public var key: AgentSessionKey {
        AgentSessionKey(provider: provider, sessionID: sessionID)
    }
}

public struct AgentSessionSnapshot: Equatable, Sendable {
    public let key: AgentSessionKey
    public let status: AgentStatus
    public let displayName: AgentSessionDisplayName?

    public init(key: AgentSessionKey, status: AgentStatus, displayName: AgentSessionDisplayName? = nil) {
        self.key = key
        self.status = status
        self.displayName = displayName
    }

    public var provider: AgentProvider { key.provider }
    public var sessionID: String { key.sessionID }
    public var displayText: String { status.displayText }
    public var detailText: String { displayName?.value ?? status.detailText }
    public var animation: AnimationState { status.animation }
    public var indicatorTone: AgentStatusTone { status.indicatorTone }
}

public struct AgentSessionStore: Sendable {
    public static let maximumEntries = 5

    public private(set) var entries: [AgentSessionSnapshot] = []
    public private(set) var selectedIndex = 0

    public init() {}

    public var selected: AgentSessionSnapshot? {
        guard entries.indices.contains(selectedIndex) else { return nil }
        return entries[selectedIndex]
    }

    public mutating func upsert(_ event: NormalizedAgentEvent) {
        let existing = entries.first { $0.key == event.key }
        let displayName = preferredDisplayName(existing: existing?.displayName, candidate: event.displayName)
        let snapshot = AgentSessionSnapshot(key: event.key, status: event.status, displayName: displayName)
        entries.removeAll { $0.key == event.key }
        entries.insert(snapshot, at: 0)
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        selectedIndex = 0
    }

    @discardableResult
    public mutating func setDisplayName(_ displayName: AgentSessionDisplayName, for key: AgentSessionKey) -> Bool {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return false }
        let existing = entries[index]
        guard let preferred = preferredDisplayName(existing: existing.displayName, candidate: displayName), preferred != existing.displayName else {
            return false
        }
        entries[index] = AgentSessionSnapshot(key: existing.key, status: existing.status, displayName: preferred)
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
        if let selectedKey, let preservedIndex = entries.firstIndex(where: { $0.key == selectedKey }) {
            selectedIndex = preservedIndex
        } else {
            selectedIndex = min(selectedIndex, max(0, entries.count - 1))
        }
        return true
    }

    private func preferredDisplayName(
        existing: AgentSessionDisplayName?,
        candidate: AgentSessionDisplayName?
    ) -> AgentSessionDisplayName? {
        guard let candidate else { return existing }
        guard let existing else { return candidate }
        if candidate.source > existing.source { return candidate }
        if candidate.source == .nativeProvider, candidate.value != existing.value { return candidate }
        return existing
    }
}
