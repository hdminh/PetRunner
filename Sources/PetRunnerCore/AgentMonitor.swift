import CryptoKit
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

public enum AgentSessionLabel {
    public static func labels(for keys: [AgentSessionKey]) -> [AgentSessionKey: String] {
        labels(for: keys, fingerprint: fingerprint(for:))
    }

    static func labels(
        for keys: [AgentSessionKey],
        fingerprint: (AgentSessionKey) -> String
    ) -> [AgentSessionKey: String] {
        let uniqueKeys = keys.reduce(into: [AgentSessionKey]()) { result, key in
            if !result.contains(key) { result.append(key) }
        }
        let fingerprints = Dictionary(uniqueKeys.map { key in
            (key, fingerprint(key).uppercased())
        }, uniquingKeysWith: { first, _ in first })
        var lengths = Dictionary(uniqueKeys.map { key in
            (key, min(6, fingerprints[key]?.count ?? 0))
        }, uniquingKeysWith: { first, _ in first })

        while true {
            let groups = Dictionary(grouping: uniqueKeys) { key in
                let value = fingerprints[key] ?? ""
                let length = lengths[key] ?? 0
                return String(value.prefix(length))
            }
            let collisions = groups.values.filter { $0.count > 1 }
            guard !collisions.isEmpty else { break }

            var extended = false
            for collision in collisions {
                for key in collision {
                    let maximum = fingerprints[key]?.count ?? 0
                    let current = lengths[key] ?? 0
                    if current < maximum {
                        lengths[key] = min(current + 2, maximum)
                        extended = true
                    }
                }
            }
            guard extended else { break }
        }

        let finalGroups = Dictionary(grouping: uniqueKeys) { key in
            let value = fingerprints[key] ?? ""
            let length = lengths[key] ?? 0
            return String(value.prefix(length))
        }
        var result: [AgentSessionKey: String] = [:]
        for (prefix, group) in finalGroups {
            if group.count == 1, let key = group.first {
                result[key] = "SESSION \(prefix)"
            } else {
                for (index, key) in group.sorted(by: sessionKeySort).enumerated() {
                    result[key] = "SESSION \(prefix) \(index + 1)"
                }
            }
        }
        return result
    }

    private static func fingerprint(for key: AgentSessionKey) -> String {
        let value = sessionKeyValue(key)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private static func sessionKeySort(_ lhs: AgentSessionKey, _ rhs: AgentSessionKey) -> Bool {
        sessionKeyValue(lhs) < sessionKeyValue(rhs)
    }

    private static func sessionKeyValue(_ key: AgentSessionKey) -> String {
        "\(key.provider.rawValue)\u{1F}\(key.sessionID)"
    }
}

public struct NormalizedAgentEvent: Equatable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let status: AgentStatus

    public init(provider: AgentProvider, sessionID: String, status: AgentStatus) {
        self.provider = provider
        self.sessionID = sessionID
        self.status = status
    }

    public var key: AgentSessionKey {
        AgentSessionKey(provider: provider, sessionID: sessionID)
    }
}

public struct AgentSessionSnapshot: Equatable, Sendable {
    public let key: AgentSessionKey
    public let status: AgentStatus

    public init(key: AgentSessionKey, status: AgentStatus) {
        self.key = key
        self.status = status
    }

    public var provider: AgentProvider { key.provider }
    public var sessionID: String { key.sessionID }
    public var displayText: String { status.displayText }
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
        let snapshot = AgentSessionSnapshot(key: event.key, status: event.status)
        entries.removeAll { $0.key == event.key }
        entries.insert(snapshot, at: 0)
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        selectedIndex = 0
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
}
