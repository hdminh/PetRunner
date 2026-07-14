@testable import PetRunnerCore
import Foundation
import SQLite3
import Testing

struct CursorSessionTitleResolverTests {
    @Test func readsOnlyTheMatchingCursorConversationTitle() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try createDatabase(at: url)
        let originalData = try Data(contentsOf: url)

        let resolver = CursorSessionTitleResolver(databaseURL: url)

        #expect(resolver.displayName(for: "conversation-a")?.value == "Native Cursor title")
        #expect(resolver.displayName(for: "missing") == nil)
        #expect(try Data(contentsOf: url) == originalData)
    }

    @Test func treatsMissingOrIncompatibleDatabasesAsNoTitle() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(CursorSessionTitleResolver(databaseURL: missing).displayName(for: "conversation") == nil)

        let incompatible = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: incompatible) }
        try Data("not a database".utf8).write(to: incompatible)
        #expect(CursorSessionTitleResolver(databaseURL: incompatible).displayName(for: "conversation") == nil)
    }

    @Test func returnsNoTitleWhenCursorDatabaseIsLocked() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try createDatabase(at: url)

        var writer: OpaquePointer?
        guard sqlite3_open(url.path, &writer) == SQLITE_OK, let writer else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(writer) }
        guard sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { _ = sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        #expect(CursorSessionTitleResolver(databaseURL: url).displayName(for: "conversation-a") == nil)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("petrunner-title-\(UUID().uuidString).sqlite")
    }

    private func createDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        let query = "CREATE TABLE conversations (id TEXT PRIMARY KEY, title TEXT NOT NULL); INSERT INTO conversations (id, title) VALUES ('conversation-a', 'Native Cursor title');"
        guard sqlite3_exec(database, query, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
