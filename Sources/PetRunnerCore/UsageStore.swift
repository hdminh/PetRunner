import Foundation
import SQLite3

public final class UsageStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw UsageStoreError.open }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS usage_records (source_key TEXT PRIMARY KEY, provider TEXT NOT NULL, session_id TEXT NOT NULL, occurred_at REAL NOT NULL, model TEXT, input_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL, cache_creation_tokens INTEGER NOT NULL DEFAULT 0, cache_creation_1h_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL, reasoning_tokens INTEGER NOT NULL, cost_usd REAL, provenance TEXT NOT NULL, pricing_version TEXT, budget_eligible INTEGER NOT NULL, usage_type TEXT)")
        // Existing installations have the original narrower token schema.
        // These migrations retain their historical rows with zero cache writes.
        try? execute("ALTER TABLE usage_records ADD COLUMN cache_creation_tokens INTEGER NOT NULL DEFAULT 0")
        try? execute("ALTER TABLE usage_records ADD COLUMN cache_creation_1h_tokens INTEGER NOT NULL DEFAULT 0")
        try? execute("ALTER TABLE usage_records ADD COLUMN usage_type TEXT")
        try execute("CREATE TABLE IF NOT EXISTS usage_sessions (provider TEXT NOT NULL, session_id TEXT NOT NULL, project_name TEXT, title TEXT, started_at REAL NOT NULL, last_activity_at REAL NOT NULL, model TEXT, source_revision TEXT NOT NULL, PRIMARY KEY(provider, session_id))")
        try? execute("ALTER TABLE usage_sessions ADD COLUMN project_path TEXT")
        try? execute("INSERT OR IGNORE INTO usage_sessions (provider,session_id,project_name,title,started_at,last_activity_at,model,source_revision) SELECT provider,session_id,project_name,title,started_at,last_activity_at,model,'\(LocalUsageSource.historicalParserRevision)' FROM historical_usage_sessions")
        try execute("CREATE TABLE IF NOT EXISTS usage_source_checkpoints (source_key TEXT PRIMARY KEY, updated_at REAL NOT NULL, state TEXT NOT NULL, detail TEXT)")
        try execute("DELETE FROM usage_source_checkpoints WHERE state = 'historical-usage-receipt' AND detail NOT LIKE '%\(LocalUsageSource.historicalParserRevision)%'")
        try execute("CREATE TABLE IF NOT EXISTS budget_alert_receipts (receipt_key TEXT PRIMARY KEY, created_at REAL NOT NULL)")
    }

    deinit { sqlite3_close(database) }

    public func upsert(_ records: [AgentUsageRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !records.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO usage_records (source_key,provider,session_id,occurred_at,model,input_tokens,cached_input_tokens,cache_creation_tokens,cache_creation_1h_tokens,output_tokens,reasoning_tokens,cost_usd,provenance,pricing_version,budget_eligible,usage_type) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(record.id, at: 1, statement); bind(record.provider.rawValue, at: 2, statement); bind(record.sessionID, at: 3, statement)
                sqlite3_bind_double(statement, 4, record.occurredAt.timeIntervalSince1970)
                bind(record.model, at: 5, statement)
                sqlite3_bind_int64(statement, 6, Int64(record.tokens.input)); sqlite3_bind_int64(statement, 7, Int64(record.tokens.cachedInput)); sqlite3_bind_int64(statement, 8, Int64(record.tokens.cacheCreation)); sqlite3_bind_int64(statement, 9, Int64(record.tokens.cacheCreation1h)); sqlite3_bind_int64(statement, 10, Int64(record.tokens.output)); sqlite3_bind_int64(statement, 11, Int64(record.tokens.reasoning))
                if let cost = record.cost.usd { sqlite3_bind_double(statement, 12, cost) } else { sqlite3_bind_null(statement, 12) }
                bind(record.cost.provenance.rawValue, at: 13, statement); bind(record.cost.pricingVersion, at: 14, statement); sqlite3_bind_int(statement, 15, record.cost.isBudgetEligible ? 1 : 0)
                bind(record.usageType?.rawValue, at: 16, statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Replaces every stored row for a provider. Used for Cursor's live usage-events
    /// ledger so progressive token updates cannot accumulate under unstable keys.
    public func replaceRecords(provider: UsageProvider, with records: [AgentUsageRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            var delete: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM usage_records WHERE provider = ?", -1, &delete, nil) == SQLITE_OK else {
                throw UsageStoreError.statement
            }
            defer { sqlite3_finalize(delete) }
            bind(provider.rawValue, at: 1, delete)
            guard sqlite3_step(delete) == SQLITE_DONE else { throw UsageStoreError.statement }

            if !records.isEmpty {
                var statement: OpaquePointer?
                let sql = "INSERT OR REPLACE INTO usage_records (source_key,provider,session_id,occurred_at,model,input_tokens,cached_input_tokens,cache_creation_tokens,cache_creation_1h_tokens,output_tokens,reasoning_tokens,cost_usd,provenance,pricing_version,budget_eligible,usage_type) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }
                defer { sqlite3_finalize(statement) }
                for record in records {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    bind(record.id, at: 1, statement); bind(record.provider.rawValue, at: 2, statement); bind(record.sessionID, at: 3, statement)
                    sqlite3_bind_double(statement, 4, record.occurredAt.timeIntervalSince1970)
                    bind(record.model, at: 5, statement)
                    sqlite3_bind_int64(statement, 6, Int64(record.tokens.input)); sqlite3_bind_int64(statement, 7, Int64(record.tokens.cachedInput)); sqlite3_bind_int64(statement, 8, Int64(record.tokens.cacheCreation)); sqlite3_bind_int64(statement, 9, Int64(record.tokens.cacheCreation1h)); sqlite3_bind_int64(statement, 10, Int64(record.tokens.output)); sqlite3_bind_int64(statement, 11, Int64(record.tokens.reasoning))
                    if let cost = record.cost.usd { sqlite3_bind_double(statement, 12, cost) } else { sqlite3_bind_null(statement, 12) }
                    bind(record.cost.provenance.rawValue, at: 13, statement); bind(record.cost.pricingVersion, at: 14, statement); sqlite3_bind_int(statement, 15, record.cost.isBudgetEligible ? 1 : 0)
                    bind(record.usageType?.rawValue, at: 16, statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func records(matching query: UsageQuery = .init()) throws -> [AgentUsageRecord] {
        lock.lock(); defer { lock.unlock() }
        var clauses: [String] = []; var values: [Any] = []
        if let providers = query.providers, !providers.isEmpty { clauses.append("provider IN (\(providers.map { _ in "?" }.joined(separator: ",")))"); values += providers.map(\.rawValue) }
        if let start = query.startDate { clauses.append("occurred_at >= ?"); values.append(start.timeIntervalSince1970) }
        if let end = query.endDate { clauses.append("occurred_at < ?"); values.append(end.timeIntervalSince1970) }
        if let sessionID = query.sessionID { clauses.append("session_id = ?"); values.append(sessionID) }
        let sql = "SELECT source_key,provider,session_id,occurred_at,model,input_tokens,cached_input_tokens,cache_creation_tokens,cache_creation_1h_tokens,output_tokens,reasoning_tokens,cost_usd,provenance,pricing_version,budget_eligible,usage_type FROM usage_records\(clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) ORDER BY occurred_at DESC"
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }; defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { if let string = value as? String { bind(string, at: Int32(index + 1), statement) } else if let number = value as? Double { sqlite3_bind_double(statement, Int32(index + 1), number) } }
        var result: [AgentUsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnString(statement, 0), let rawProvider = columnString(statement, 1), let provider = UsageProvider(rawValue: rawProvider), let session = columnString(statement, 2), let provenanceRaw = columnString(statement, 12), let provenance = UsageCostProvenance(rawValue: provenanceRaw) else { continue }
            let model = columnString(statement, 4); let cost = sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 11)
            let usageType = columnString(statement, 15).flatMap(UsageBillingType.init(rawValue:))
            result.append(.init(id: id, provider: provider, sessionID: session, occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), model: model, tokens: .init(input: Int(sqlite3_column_int64(statement, 5)), cachedInput: Int(sqlite3_column_int64(statement, 6)), cacheCreation: Int(sqlite3_column_int64(statement, 7)), cacheCreation1h: Int(sqlite3_column_int64(statement, 8)), output: Int(sqlite3_column_int64(statement, 9)), reasoning: Int(sqlite3_column_int64(statement, 10))), cost: .init(usd: cost, provenance: provenance, pricingVersion: columnString(statement, 13), isBudgetEligible: sqlite3_column_int(statement, 14) != 0), usageType: usageType))
        }
        return result
    }

    public func upsert(sessions: [HistoricalUsageSession]) throws {
        lock.lock(); defer { lock.unlock() }
        for session in sessions {
            try upsertSessionLocked(session)
        }
    }

    /// Replaces all session metadata rows for a provider. Used for Cursor so
    /// local workspace attribution can overwrite stale `"Cursor"` placeholders.
    public func replaceSessions(provider: UsageProvider, with sessions: [HistoricalUsageSession]) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            var delete: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM usage_sessions WHERE provider = ?", -1, &delete, nil) == SQLITE_OK else {
                throw UsageStoreError.statement
            }
            defer { sqlite3_finalize(delete) }
            bind(provider.rawValue, at: 1, delete)
            guard sqlite3_step(delete) == SQLITE_DONE else { throw UsageStoreError.statement }
            for session in sessions where session.provider == provider {
                try upsertSessionLocked(session)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func upsertSessionLocked(_ session: HistoricalUsageSession) throws {
        let sql = """
            INSERT INTO usage_sessions (provider,session_id,project_name,title,started_at,last_activity_at,model,source_revision,project_path)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(provider,session_id) DO UPDATE SET
                project_name=COALESCE(usage_sessions.project_name,excluded.project_name),
                project_path=COALESCE(usage_sessions.project_path,excluded.project_path),
                title=COALESCE(excluded.title,usage_sessions.title),
                started_at=MIN(usage_sessions.started_at,excluded.started_at),
                last_activity_at=MAX(usage_sessions.last_activity_at,excluded.last_activity_at),
                model=CASE WHEN excluded.last_activity_at > usage_sessions.last_activity_at
                    THEN COALESCE(excluded.model,usage_sessions.model)
                    ELSE COALESCE(usage_sessions.model,excluded.model) END,
                source_revision=excluded.source_revision
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }
        defer { sqlite3_finalize(statement) }
        bind(session.provider.rawValue, at: 1, statement); bind(session.sessionID, at: 2, statement)
        bind(session.projectName, at: 3, statement); bind(session.title, at: 4, statement)
        sqlite3_bind_double(statement, 5, session.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, session.lastActivityAt.timeIntervalSince1970)
        bind(session.model, at: 7, statement)
        bind(session.sourceRevision, at: 8, statement)
        bind(session.projectPath, at: 9, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
    }

    public func upsert(_ scan: HistoricalUsageScan) throws {
        try upsert(scan.records)
        try upsert(sessions: scan.sessions)
        try save(sourceReceipts: scan.sourceReceipts)
    }

    public func sessions(matching query: HistoricalUsageSessionQuery = .init()) throws -> [HistoricalUsageSession] {
        lock.lock(); defer { lock.unlock() }
        var clauses: [String] = []; var values: [Any] = []
        if let providers = query.providers, !providers.isEmpty { clauses.append("provider IN (\(providers.map { _ in "?" }.joined(separator: ",")))"); values += providers.map(\.rawValue) }
        if let start = query.startDate { clauses.append("last_activity_at >= ?"); values.append(start.timeIntervalSince1970) }
        if let end = query.endDate { clauses.append("last_activity_at < ?"); values.append(end.timeIntervalSince1970) }
        if let sessionID = query.sessionID { clauses.append("session_id = ?"); values.append(sessionID) }
        let sql = "SELECT provider,session_id,project_name,title,started_at,last_activity_at,model,source_revision,project_path FROM usage_sessions\(clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) ORDER BY last_activity_at DESC"
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }; defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { if let string = value as? String { bind(string, at: Int32(index + 1), statement) } else if let number = value as? Double { sqlite3_bind_double(statement, Int32(index + 1), number) } }
        var result: [HistoricalUsageSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawProvider = columnString(statement, 0), let provider = UsageProvider(rawValue: rawProvider), let sessionID = columnString(statement, 1) else { continue }
            result.append(.init(provider: provider, sessionID: sessionID, projectName: columnString(statement, 2), title: columnString(statement, 3), startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)), lastActivityAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)), model: columnString(statement, 6), sourceRevision: columnString(statement, 7) ?? LocalUsageSource.historicalParserRevision, projectPath: columnString(statement, 8)))
        }
        return result
    }

    public func save(sourceReceipts: [HistoricalUsageSourceReceipt]) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        for receipt in sourceReceipts {
            guard let detail = String(data: try encoder.encode(receipt), encoding: .utf8) else { throw UsageStoreError.statement }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO usage_source_checkpoints (source_key,updated_at,state,detail) VALUES (?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }
            defer { sqlite3_finalize(statement) }
            bind(receipt.sourceKey, at: 1, statement); sqlite3_bind_double(statement, 2, receipt.modifiedAt.timeIntervalSince1970)
            bind("historical-usage-receipt", at: 3, statement); bind(detail, at: 4, statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
        }
    }

    /// Returns only source files whose mtime, size, or parser revision differs
    /// from the receipt persisted by a prior historical scan.
    public func changedSources(_ receipts: [HistoricalUsageSourceReceipt]) throws -> [HistoricalUsageSourceReceipt] {
        lock.lock(); defer { lock.unlock() }
        let decoder = JSONDecoder()
        return try receipts.filter { receipt in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT detail FROM usage_source_checkpoints WHERE source_key = ? AND state = ?", -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }
            defer { sqlite3_finalize(statement) }
            bind(receipt.sourceKey, at: 1, statement); bind("historical-usage-receipt", at: 2, statement)
            guard sqlite3_step(statement) == SQLITE_ROW, let detail = columnString(statement, 0), let data = detail.data(using: .utf8), let saved = try? decoder.decode(HistoricalUsageSourceReceipt.self, from: data) else { return true }
            return saved != receipt
        }
    }

    public func aggregate(_ query: UsageQuery = .init()) throws -> UsageAggregate { UsageAggregate(records: try records(matching: query)) }

    public func saveReceipt(_ receipt: BudgetAlertReceipt) throws {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO budget_alert_receipts (receipt_key,created_at) VALUES (?,?)", -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }; defer { sqlite3_finalize(statement) }
        bind(receipt.key, at: 1, statement); sqlite3_bind_double(statement, 2, receipt.createdAt.timeIntervalSince1970); guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
    }

    public func hasReceipt(_ key: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, "SELECT 1 FROM budget_alert_receipts WHERE receipt_key = ?", -1, &statement, nil) == SQLITE_OK else { throw UsageStoreError.statement }; defer { sqlite3_finalize(statement) }; bind(key, at: 1, statement); return sqlite3_step(statement) == SQLITE_ROW
    }

    private func execute(_ sql: String) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw UsageStoreError.statement } }
    private func bind(_ value: String?, at index: Int32, _ statement: OpaquePointer?) { guard let value else { sqlite3_bind_null(statement, index); return }; sqlite3_bind_text(statement, index, value, -1, sqliteTransient) }
}

public enum UsageStoreError: Error { case open, statement }
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? { sqlite3_column_text(statement, index).map { String(cString: $0) } }
