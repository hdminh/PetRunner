import Foundation
import SQLite3

/// Best-effort reader for Cursor's local conversation index. It never writes to Cursor data.
public struct CursorSessionTitleResolver: Sendable {
    public static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/conversation-search.db")

    public let databaseURL: URL

    public init(databaseURL: URL = Self.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    public func displayName(for conversationID: String) -> AgentSessionDisplayName? {
        guard !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)

        var statement: OpaquePointer?
        let query = "SELECT title FROM conversations WHERE id = ? LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let stepResult = conversationID.withCString { value in
            guard sqlite3_bind_text(statement, 1, value, -1, transient) == SQLITE_OK else { return SQLITE_ERROR }
            return sqlite3_step(statement)
        }
        guard stepResult == SQLITE_ROW, let title = sqlite3_column_text(statement, 0) else { return nil }
        return AgentSessionDisplayName.sanitized(String(cString: title), source: .nativeProvider)
    }
}
