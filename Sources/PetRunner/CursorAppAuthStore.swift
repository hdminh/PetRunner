import Foundation
import SQLite3

/// Reads Cursor.app's local login so PetRunner can request usage without a pasted cookie.
/// Prefers the IDE `state.vscdb` access token and builds the WorkOS session cookie header.
struct CursorAppAuthStore {
    enum AuthError: Error {
        case notSignedIn
        case invalidToken
    }

    private var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    func cookieHeader() throws -> String {
        guard let accessToken = readItem("cursorAuth/accessToken"), !accessToken.isEmpty else {
            throw AuthError.notSignedIn
        }
        guard let subject = jwtSubject(accessToken), !subject.isEmpty else {
            throw AuthError.invalidToken
        }
        // Cursor's web APIs expect the WorkOS session cookie with URL-encoded separators.
        return "WorkosCursorSessionToken=\(subject)%3A%3A\(accessToken)"
    }

    func cachedEmail() -> String? {
        nonempty(readItem("cursorAuth/cachedEmail"))
    }

    func membershipType() -> String? {
        nonempty(readItem("cursorAuth/stripeMembershipType"))
    }

    private func readItem(_ key: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: bytes)
    }

    private func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        guard let claims = decodeJWTPayload(String(parts[1])) else { return nil }
        return claims["sub"] as? String
    }

    private func decodeJWTPayload(_ segment: String) -> [String: Any]? {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
