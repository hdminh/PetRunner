import Foundation
import SQLite3

public enum AgentSessionHistoryError: Error, LocalizedError {
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case let .sqlite(message): message
        }
    }
}

public struct AgentSessionHistoryQuery: Equatable, Sendable {
    public var provider: AgentProvider?
    public var model: AgentSessionModel?
    public var searchText: String?
    public var startDate: Date?

    public init(
        provider: AgentProvider? = nil,
        model: AgentSessionModel? = nil,
        searchText: String? = nil,
        startDate: Date? = nil
    ) {
        self.provider = provider
        self.model = model
        self.searchText = searchText
        self.startDate = startDate
    }
}

public struct AgentSessionHistorySummary: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let provider: AgentProvider
    public let status: AgentStatus
    public let model: AgentSessionModel?
    public let activity: AgentActivity?
    public let agentType: AgentSubagentType?
    public let sessionName: AgentSessionName?
    public let estimatedCost: AgentSessionEstimatedCost?
    public let firstSeenAt: Date
    public let updatedAt: Date
    public let finishedAt: Date?
}

public struct AgentSessionTimelineEntry: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let occurredAt: Date
    public let status: AgentStatus
    public let model: AgentSessionModel?
    public let activity: AgentActivity?
    public let agentType: AgentSubagentType?
    public let sessionName: AgentSessionName?
    public let estimatedCost: AgentSessionEstimatedCost?
}

public final class AgentSessionHistoryStore {
    public static let defaultMaximumAge: TimeInterval = 90 * 24 * 60 * 60

    private let database: OpaquePointer
    private let maximumAge: TimeInterval

    public init(url: URL, maximumAge: TimeInterval = AgentSessionHistoryStore.defaultMaximumAge) throws {
        self.maximumAge = maximumAge
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw AgentSessionHistoryError.sqlite("Could not open session history")
        }
        database = handle
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = DELETE")
            try createSchema()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    @discardableResult
    public func record(_ event: NormalizedAgentEvent, at date: Date = Date()) throws -> Bool {
        try prune(at: date)
        let key = persistedKey(for: event.key)
        if let existing = try storedSession(matching: key) {
            let merged = existing.merging(event: event, at: date)
            guard existing.isSemanticallyDifferent(from: merged) else { return false }
            try update(merged)
            try insertTimeline(for: merged, at: date)
            return true
        }

        let session = StoredSession(event: event, id: 0, firstSeenAt: date, updatedAt: date, finishedAt: terminalDate(for: event.status, at: date))
        let id = try insert(session, key: key)
        try insertTimeline(for: session.withID(id), at: date)
        return true
    }

    public func summaries(at date: Date = Date()) throws -> [AgentSessionHistorySummary] {
        try summaries(matching: AgentSessionHistoryQuery(), at: date)
    }

    public func summaries(matching query: AgentSessionHistoryQuery, at date: Date = Date()) throws -> [AgentSessionHistorySummary] {
        try prune(at: date)
        var clauses: [String] = []
        var values: [Binding] = []
        if let provider = query.provider {
            clauses.append("provider = ?")
            values.append(.text(provider.rawValue))
        }
        if let model = query.model {
            clauses.append("model = ?")
            values.append(.text(model.value))
        }
        if let startDate = query.startDate {
            clauses.append("updated_at >= ?")
            values.append(.double(startDate.timeIntervalSinceReferenceDate))
        }
        if let search = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            clauses.append("LOWER(COALESCE(session_name, '') || ' ' || COALESCE(activity, '')) LIKE ?")
            values.append(.text("%\(search.lowercased())%"))
        }
        let predicate = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let statement = try prepare("""
            SELECT id, provider, status, model, activity, agent_type, session_name, estimated_cost, first_seen_at, updated_at, finished_at
            FROM sessions\(predicate)
            ORDER BY updated_at DESC, id DESC
            """)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)

        var result: [AgentSessionHistorySummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try summary(from: statement))
        }
        try requireDone(statement)
        return result
    }

    public func timeline(for sessionID: Int64) throws -> [AgentSessionTimelineEntry] {
        let statement = try prepare("""
            SELECT id, occurred_at, status, model, activity, agent_type, session_name, estimated_cost
            FROM timeline WHERE session_id = ? ORDER BY occurred_at ASC, id ASC
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.int64(sessionID)], to: statement)

        var result: [AgentSessionTimelineEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try timelineEntry(from: statement))
        }
        try requireDone(statement)
        return result
    }

    public func clear() throws { try execute("DELETE FROM sessions") }

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY,
                provider TEXT NOT NULL,
                session_id TEXT NOT NULL,
                scope_kind TEXT NOT NULL,
                agent_id TEXT,
                status TEXT NOT NULL,
                model TEXT,
                activity TEXT,
                agent_type TEXT,
                session_name TEXT,
                estimated_cost TEXT,
                first_seen_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                finished_at REAL,
                UNIQUE(provider, session_id, scope_kind, agent_id)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS timeline (
                id INTEGER PRIMARY KEY,
                session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                occurred_at REAL NOT NULL,
                status TEXT NOT NULL,
                model TEXT,
                activity TEXT,
                agent_type TEXT,
                session_name TEXT,
                estimated_cost TEXT
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS sessions_updated_at ON sessions(updated_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS timeline_session_id ON timeline(session_id, occurred_at ASC)")
    }

    private func prune(at date: Date) throws {
        let statement = try prepare("DELETE FROM sessions WHERE updated_at < ?")
        defer { sqlite3_finalize(statement) }
        try bind([.double(date.addingTimeInterval(-maximumAge).timeIntervalSinceReferenceDate)], to: statement)
        try stepDone(statement)
    }

    private func storedSession(matching key: PersistedKey) throws -> StoredSession? {
        let statement = try prepare("""
            SELECT id, provider, status, model, activity, agent_type, session_name, estimated_cost, first_seen_at, updated_at, finished_at
            FROM sessions WHERE provider = ? AND session_id = ? AND scope_kind = ? AND agent_id IS ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.text(key.provider.rawValue), .text(key.sessionID), .text(key.scopeKind), .text(key.agentID)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try storedSession(from: statement)
        case SQLITE_DONE: return nil
        default: throw error()
        }
    }

    private func insert(_ session: StoredSession, key: PersistedKey) throws -> Int64 {
        let statement = try prepare("""
            INSERT INTO sessions (provider, session_id, scope_kind, agent_id, status, model, activity, agent_type, session_name, estimated_cost, first_seen_at, updated_at, finished_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(key.provider.rawValue), .text(key.sessionID), .text(key.scopeKind), .text(key.agentID),
            .text(session.status.rawValue), .text(session.model?.value), .text(session.activity?.value),
            .text(session.agentType?.value), .text(session.sessionName?.value), .text(costText(session.estimatedCost)),
            .double(session.firstSeenAt.timeIntervalSinceReferenceDate), .double(session.updatedAt.timeIntervalSinceReferenceDate),
            .date(session.finishedAt)
        ], to: statement)
        try stepDone(statement)
        return sqlite3_last_insert_rowid(database)
    }

    private func update(_ session: StoredSession) throws {
        let statement = try prepare("""
            UPDATE sessions SET status = ?, model = ?, activity = ?, agent_type = ?, session_name = ?, estimated_cost = ?, updated_at = ?, finished_at = ?
            WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind([
            .text(session.status.rawValue), .text(session.model?.value), .text(session.activity?.value),
            .text(session.agentType?.value), .text(session.sessionName?.value), .text(costText(session.estimatedCost)),
            .double(session.updatedAt.timeIntervalSinceReferenceDate), .date(session.finishedAt), .int64(session.id)
        ], to: statement)
        try stepDone(statement)
    }

    private func insertTimeline(for session: StoredSession, at date: Date) throws {
        let statement = try prepare("""
            INSERT INTO timeline (session_id, occurred_at, status, model, activity, agent_type, session_name, estimated_cost)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        try bind([
            .int64(session.id), .double(date.timeIntervalSinceReferenceDate), .text(session.status.rawValue),
            .text(session.model?.value), .text(session.activity?.value), .text(session.agentType?.value),
            .text(session.sessionName?.value), .text(costText(session.estimatedCost))
        ], to: statement)
        try stepDone(statement)
    }

    private func summary(from statement: OpaquePointer) throws -> AgentSessionHistorySummary {
        AgentSessionHistorySummary(
            id: sqlite3_column_int64(statement, 0),
            provider: try provider(columnText(statement, 1)),
            status: try status(columnText(statement, 2)),
            model: model(columnText(statement, 3)),
            activity: activity(columnText(statement, 4)),
            agentType: agentType(columnText(statement, 5)),
            sessionName: sessionName(columnText(statement, 6)),
            estimatedCost: cost(columnText(statement, 7)),
            firstSeenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 9)),
            finishedAt: columnDate(statement, 10)
        )
    }

    private func timelineEntry(from statement: OpaquePointer) throws -> AgentSessionTimelineEntry {
        AgentSessionTimelineEntry(
            id: sqlite3_column_int64(statement, 0),
            occurredAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
            status: try status(columnText(statement, 2)),
            model: model(columnText(statement, 3)),
            activity: activity(columnText(statement, 4)),
            agentType: agentType(columnText(statement, 5)),
            sessionName: sessionName(columnText(statement, 6)),
            estimatedCost: cost(columnText(statement, 7))
        )
    }

    private func storedSession(from statement: OpaquePointer) throws -> StoredSession {
        StoredSession(
            id: sqlite3_column_int64(statement, 0),
            provider: try provider(columnText(statement, 1)),
            status: try status(columnText(statement, 2)),
            model: model(columnText(statement, 3)),
            activity: activity(columnText(statement, 4)),
            agentType: agentType(columnText(statement, 5)),
            sessionName: sessionName(columnText(statement, 6)),
            estimatedCost: cost(columnText(statement, 7)),
            firstSeenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 9)),
            finishedAt: columnDate(statement, 10)
        )
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw AgentSessionHistoryError.sqlite(message.map { String(cString: $0) } ?? "Session history database error")
        }
    }

    private func bind(_ values: [Binding], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case let .text(text):
                status = text.map { value in
                    value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
                } ?? sqlite3_bind_null(statement, index)
            case let .double(value): status = sqlite3_bind_double(statement, index, value)
            case let .int64(value): status = sqlite3_bind_int64(statement, index, value)
            case let .date(value):
                status = value.map { sqlite3_bind_double(statement, index, $0.timeIntervalSinceReferenceDate) } ?? sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw error() }
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func requireDone(_ statement: OpaquePointer) throws {
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else { throw error() }
    }

    private func error() -> AgentSessionHistoryError {
        AgentSessionHistoryError.sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private func provider(_ value: String?) throws -> AgentProvider {
        guard let value, let provider = AgentProvider(rawValue: value) else { throw AgentSessionHistoryError.sqlite("Invalid provider in session history") }
        return provider
    }

    private func status(_ value: String?) throws -> AgentStatus {
        guard let value, let status = AgentStatus(rawValue: value) else { throw AgentSessionHistoryError.sqlite("Invalid status in session history") }
        return status
    }

    private func model(_ value: String?) -> AgentSessionModel? { value.flatMap(AgentSessionModel.sanitized) }
    private func activity(_ value: String?) -> AgentActivity? { value.flatMap(AgentActivity.sanitized) }
    private func agentType(_ value: String?) -> AgentSubagentType? { value.flatMap(AgentSubagentType.sanitized) }
    private func sessionName(_ value: String?) -> AgentSessionName? { value.flatMap(AgentSessionName.sanitized) }
    private func cost(_ value: String?) -> AgentSessionEstimatedCost? { value.flatMap { Decimal(string: $0) }.flatMap(AgentSessionEstimatedCost.init) }
    private func costText(_ value: AgentSessionEstimatedCost?) -> String? { value.map { NSDecimalNumber(decimal: $0.usd).stringValue } }
    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? { sqlite3_column_text(statement, index).map { String(cString: $0) } }
    private func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index))
    }
    private func terminalDate(for status: AgentStatus, at date: Date) -> Date? { status == .finished || status == .failed ? date : nil }

    private func persistedKey(for key: AgentSessionKey) -> PersistedKey {
        switch key.scope {
        case .primary: PersistedKey(provider: key.provider, sessionID: key.sessionID, scopeKind: "primary", agentID: nil)
        case let .subagent(agentID): PersistedKey(provider: key.provider, sessionID: key.sessionID, scopeKind: "subagent", agentID: agentID)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum Binding {
    case text(String?)
    case double(Double)
    case int64(Int64)
    case date(Date?)
}

private struct PersistedKey {
    let provider: AgentProvider
    let sessionID: String
    let scopeKind: String
    let agentID: String?
}

private struct StoredSession {
    var id: Int64
    let provider: AgentProvider
    var status: AgentStatus
    var model: AgentSessionModel?
    var activity: AgentActivity?
    var agentType: AgentSubagentType?
    var sessionName: AgentSessionName?
    var estimatedCost: AgentSessionEstimatedCost?
    let firstSeenAt: Date
    var updatedAt: Date
    var finishedAt: Date?

    init(
        id: Int64,
        provider: AgentProvider,
        status: AgentStatus,
        model: AgentSessionModel?,
        activity: AgentActivity?,
        agentType: AgentSubagentType?,
        sessionName: AgentSessionName?,
        estimatedCost: AgentSessionEstimatedCost?,
        firstSeenAt: Date,
        updatedAt: Date,
        finishedAt: Date?
    ) {
        self.id = id
        self.provider = provider
        self.status = status
        self.model = model
        self.activity = activity
        self.agentType = agentType
        self.sessionName = sessionName
        self.estimatedCost = estimatedCost
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
    }

    init(event: NormalizedAgentEvent, id: Int64, firstSeenAt: Date, updatedAt: Date, finishedAt: Date?) {
        self.init(
            id: id,
            provider: event.provider,
            status: event.status,
            model: event.model,
            activity: event.activity,
            agentType: event.agentType,
            sessionName: event.sessionName,
            estimatedCost: event.estimatedCost,
            firstSeenAt: firstSeenAt,
            updatedAt: updatedAt,
            finishedAt: finishedAt
        )
    }

    func merging(event: NormalizedAgentEvent, at date: Date) -> StoredSession {
        var result = self
        result.status = event.status
        result.model = event.model ?? model
        result.activity = event.activity ?? activity
        result.agentType = event.agentType ?? agentType
        result.sessionName = event.sessionName ?? sessionName
        result.estimatedCost = event.estimatedCost ?? estimatedCost
        result.updatedAt = date
        if event.status == .finished || event.status == .failed { result.finishedAt = date }
        return result
    }

    func isSemanticallyDifferent(from other: StoredSession) -> Bool {
        status != other.status || model != other.model || activity != other.activity || agentType != other.agentType ||
            sessionName != other.sessionName || estimatedCost != other.estimatedCost
    }

    func withID(_ id: Int64) -> StoredSession {
        var result = self
        result.id = id
        return result
    }
}
