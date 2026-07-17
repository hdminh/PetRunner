import Darwin
import Foundation

/// A short-lived, user-private handoff between hook helpers and a newly
/// launched PetRunner process. The journal stores only the already-derived
/// monitor metadata, never a hook payload or a tool result.
public struct AgentMonitorRecoveryJournal: Sendable {
    public static let maximumAge: TimeInterval = 15 * 60

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func record(_ event: NormalizedAgentEvent, at date: Date = Date()) throws {
        try withExclusiveLock {
            var records = prune(readRecords(), at: date)
            let previous = records.first { $0.key == event.key }
            records.removeAll { $0.key == event.key }
            guard event.status != .finished, event.status != .failed else {
                try write(records)
                return
            }

            records.append(Record(event: event, firstSeenAt: previous?.firstSeenAt ?? date, updatedAt: date))
            records.sort(by: newestFirst)
            try write(records)
        }
    }

    /// Returns events oldest-first so inserting them into the front of the
    /// session store recreates a newest-first, stable queue.
    public func recoveredEvents(at date: Date = Date()) throws -> [NormalizedAgentEvent] {
        try withExclusiveLock {
            let original = readRecords()
            let records = prune(original, at: date)
            if records != original { try write(records) }
            return records
                .sorted(by: oldestFirst)
                .map(\.event)
        }
    }

    public func clear() throws {
        try withExclusiveLock {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var directoryURL: URL { url.deletingLastPathComponent() }
    private var lockURL: URL { url.deletingPathExtension().appendingPathExtension("lock") }

    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EWOULDBLOCK) }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EACCES) }
        return try operation()
    }

    private func readRecords() -> [Record] {
        guard isPrivateFile(),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Payload.version
        else { return [] }
        return payload.records
    }

    private func write(_ records: [Record]) throws {
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let data = try JSONEncoder().encode(Payload(records: records))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func isPrivateFile() -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.intValue & 0o077 == 0
    }

    private func prune(_ records: [Record], at date: Date) -> [Record] {
        records.filter { date.timeIntervalSince($0.updatedAt) <= Self.maximumAge }
    }

    private func newestFirst(_ lhs: Record, _ rhs: Record) -> Bool {
        if lhs.firstSeenAt != rhs.firstSeenAt { return lhs.firstSeenAt > rhs.firstSeenAt }
        return recordIdentifier(lhs) > recordIdentifier(rhs)
    }

    private func oldestFirst(_ lhs: Record, _ rhs: Record) -> Bool {
        if lhs.firstSeenAt != rhs.firstSeenAt { return lhs.firstSeenAt < rhs.firstSeenAt }
        return recordIdentifier(lhs) < recordIdentifier(rhs)
    }

    private func recordIdentifier(_ record: Record) -> String {
        "\(record.provider.rawValue):\(record.sessionID):\(String(describing: record.scope ?? .primary))"
    }
}

private struct Payload: Codable {
    static let version = 1

    let version: Int
    let records: [Record]

    init(records: [Record]) {
        version = Self.version
        self.records = records
    }
}

private struct Record: Codable, Equatable {
    let provider: AgentProvider
    let sessionID: String
    let status: AgentStatus
    let model: AgentSessionModel?
    let activity: AgentActivity?
    let scope: AgentSessionScope?
    let agentType: AgentSubagentType?
    let sessionName: AgentSessionName?
    let estimatedCost: AgentSessionEstimatedCost?
    let firstSeenAt: Date
    let updatedAt: Date

    init(event: NormalizedAgentEvent, firstSeenAt: Date, updatedAt: Date) {
        provider = event.provider
        sessionID = event.sessionID
        status = event.status
        model = event.model
        activity = event.activity
        scope = event.scope
        agentType = event.agentType
        sessionName = event.sessionName
        estimatedCost = event.estimatedCost
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
    }

    var key: AgentSessionKey { AgentSessionKey(provider: provider, sessionID: sessionID, scope: scope ?? .primary) }

    var event: NormalizedAgentEvent {
        NormalizedAgentEvent(
            provider: provider,
            sessionID: sessionID,
            status: status,
            model: model,
            activity: activity,
            scope: scope ?? .primary,
            agentType: agentType,
            sessionName: sessionName,
            estimatedCost: estimatedCost
        )
    }
}
