import Foundation
import SQLite3

/// Local Cursor IDE metadata that attributes usage conversations to workspace
/// folders. Usage API events carry `conversationId` but not cwd; Analytics
/// projects are filled in from Cursor.app state on the same machine.
public struct CursorSessionAttribution: Sendable, Equatable {
    public let projectPath: String?
    public let projectName: String?
    public let title: String?

    public init(projectPath: String? = nil, projectName: String? = nil, title: String? = nil) {
        self.projectPath = sanitizedProjectPath(projectPath)
        self.projectName = sanitizedProjectName(projectName) ?? sanitizedProjectName(projectPath)
        self.title = sanitizedSessionTitle(title)
    }
}

public enum CursorLocalSessionIndex {
    public struct Paths: Sendable {
        public var stateDatabase: URL
        public var conversationSearchDatabase: URL?
        public var workspaceStorageDirectory: URL?
        public var cursorProjectsDirectory: URL?

        public init(
            stateDatabase: URL,
            conversationSearchDatabase: URL? = nil,
            workspaceStorageDirectory: URL? = nil,
            cursorProjectsDirectory: URL? = nil
        ) {
            self.stateDatabase = stateDatabase
            self.conversationSearchDatabase = conversationSearchDatabase
            self.workspaceStorageDirectory = workspaceStorageDirectory
            self.cursorProjectsDirectory = cursorProjectsDirectory
        }
    }

    public static func defaultPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Paths {
        let support = homeDirectory
            .appendingPathComponent("Library/Application Support/Cursor/User", isDirectory: true)
        let global = support.appendingPathComponent("globalStorage", isDirectory: true)
        return Paths(
            stateDatabase: global.appendingPathComponent("state.vscdb", isDirectory: false),
            conversationSearchDatabase: global.appendingPathComponent("conversation-search.db", isDirectory: false),
            workspaceStorageDirectory: support.appendingPathComponent("workspaceStorage", isDirectory: true),
            cursorProjectsDirectory: homeDirectory
                .appendingPathComponent(".cursor/projects", isDirectory: true)
        )
    }

    /// Maps bare conversation / composer ids (no `conv:` prefix) to workspace
    /// path, display name, and optional chat title.
    public static func load(paths: Paths = defaultPaths()) -> [String: CursorSessionAttribution] {
        var workspacePaths = workspacePathsByID(from: paths)
        var byConversation: [String: Mutable] = [:]

        if let state = openReadOnly(paths.stateDatabase) {
            defer { sqlite3_close(state) }
            mergeMembership(
                database: state,
                workspacePaths: &workspacePaths,
                into: &byConversation
            )
            mergeComposerHeaders(
                database: state,
                workspacePaths: workspacePaths,
                into: &byConversation
            )
        }

        if let searchDB = paths.conversationSearchDatabase.flatMap(openReadOnly) {
            defer { sqlite3_close(searchDB) }
            mergeConversationTitles(database: searchDB, into: &byConversation)
        }

        if let projectsDir = paths.cursorProjectsDirectory {
            mergeAgentTranscripts(
                projectsDirectory: projectsDir,
                workspacePaths: workspacePaths,
                into: &byConversation
            )
        }

        return byConversation.reduce(into: [:]) { result, item in
            let value = item.value
            guard value.projectPath != nil || value.projectName != nil || value.title != nil else { return }
            result[item.key] = CursorSessionAttribution(
                projectPath: value.projectPath,
                projectName: value.projectName,
                title: value.title
            )
        }
    }

    // MARK: - Sources

    private struct Mutable {
        var projectPath: String?
        var projectName: String?
        var title: String?
    }

    private static func mergeMembership(
        database: OpaquePointer,
        workspacePaths: inout [String: String],
        into byConversation: inout [String: Mutable]
    ) {
        guard let projectsJSON = readItem("glass.localAgentProjects.v1", database: database),
              let membershipJSON = readItem("glass.localAgentProjectMembership.v1", database: database),
              let projects = parseJSONArray(projectsJSON),
              let membership = parseJSONObject(membershipJSON)
        else { return }

        var projectByID: [String: (path: String?, name: String?)] = [:]
        for project in projects {
            guard let id = project["id"] as? String else { continue }
            let workspace = project["workspace"] as? [String: Any] ?? [:]
            let workspaceID = workspace["id"] as? String
            let uri = workspace["uri"] as? [String: Any] ?? [:]
            var path = stringValue(uri["fsPath"]) ?? stringValue(uri["path"])
            if let workspaceID, let known = workspacePaths[workspaceID] {
                path = path ?? known
            }
            if let workspaceID, let path {
                workspacePaths[workspaceID] = path
            }
            let rawName = stringValue(project["name"])
            let name: String?
            if let rawName, rawName != "New Project", !rawName.isEmpty {
                name = rawName
            } else if workspaceID == "empty-window" {
                name = "Empty window"
            } else {
                name = nil
            }
            if workspaceID == "empty-window", path == nil {
                projectByID[id] = (nil, name ?? "Empty window")
            } else {
                projectByID[id] = (path, name)
            }
        }

        for (conversationID, value) in membership {
            let projectID: String?
            if let string = value as? String {
                projectID = string
            } else {
                projectID = nil
            }
            guard let projectID, let project = projectByID[projectID] else { continue }
            upsert(
                conversationID,
                path: project.path,
                name: project.name,
                title: nil,
                into: &byConversation
            )
        }
    }

    private static func mergeComposerHeaders(
        database: OpaquePointer,
        workspacePaths: [String: String],
        into byConversation: inout [String: Mutable]
    ) {
        guard let json = readItem("composer.composerHeaders", database: database),
              let root = parseJSONObject(json),
              let composers = root["allComposers"] as? [[String: Any]]
        else { return }

        for composer in composers {
            guard let composerID = stringValue(composer["composerId"]),
                  composerID != "empty-state-draft"
            else { continue }
            let workspace = composer["workspaceIdentifier"] as? [String: Any] ?? [:]
            let uri = workspace["uri"] as? [String: Any] ?? [:]
            var path = stringValue(uri["fsPath"]) ?? stringValue(uri["path"])
            if path == nil, let workspaceID = stringValue(workspace["id"]) {
                path = workspacePaths[workspaceID]
            }
            if path == nil,
               let repos = composer["trackedGitRepos"] as? [[String: Any]],
               let repoPath = repos.first.flatMap({ stringValue($0["repoPath"]) }) {
                path = repoPath
            }
            let draftEnv = ((composer["draftTarget"] as? [String: Any])?["environment"] as? [String: Any]) ?? [:]
            if path == nil {
                let draftURI = draftEnv["uri"] as? [String: Any] ?? [:]
                path = stringValue(draftURI["fsPath"]) ?? stringValue(draftURI["path"])
            }
            let title = stringValue(composer["name"]) ?? stringValue(composer["title"])
            upsert(composerID, path: path, name: nil, title: title, into: &byConversation)
        }
    }

    private static func mergeConversationTitles(
        database: OpaquePointer,
        into byConversation: inout [String: Mutable]
    ) {
        let sql = "SELECT id, title FROM conversations WHERE title IS NOT NULL AND title != '';"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idBytes = sqlite3_column_text(statement, 0),
                  let titleBytes = sqlite3_column_text(statement, 1)
            else { continue }
            let id = String(cString: idBytes)
            let title = String(cString: titleBytes)
            upsert(id, path: nil, name: nil, title: title, into: &byConversation)
        }
    }

    private static func mergeAgentTranscripts(
        projectsDirectory: URL,
        workspacePaths: [String: String],
        into byConversation: inout [String: Mutable]
    ) {
        let encodedToPath: [String: String] = Dictionary(uniqueKeysWithValues: workspacePaths.values.map {
            (encodeWorkspaceFolderName($0), $0)
        })
        let fileManager = FileManager.default
        guard let projectFolders = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for folder in projectFolders {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            let encoded = folder.lastPathComponent
            let path = encodedToPath[encoded]
            let transcripts = folder.appendingPathComponent("agent-transcripts", isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: transcripts,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let conversationID = entry.hasDirectoryPath
                    ? entry.lastPathComponent
                    : entry.deletingPathExtension().lastPathComponent
                guard !conversationID.isEmpty else { continue }
                let name: String?
                if path == nil, encoded == "empty-window" {
                    name = "Empty window"
                } else {
                    name = nil
                }
                upsert(conversationID, path: path, name: name, title: nil, into: &byConversation)
            }
        }
    }

    private static func workspacePathsByID(from paths: Paths) -> [String: String] {
        var result: [String: String] = [:]
        if let state = openReadOnly(paths.stateDatabase) {
            defer { sqlite3_close(state) }
            if let json = readItem("workspaceMetadata.entries", database: state),
               let root = parseJSONObject(json),
               let entries = root["entries"] as? [[String: Any]] {
                for entry in entries {
                    guard let workspaceID = stringValue(entry["workspaceId"]) else { continue }
                    if let folderURI = stringValue(entry["folderUri"]),
                       let path = pathFromFileURI(folderURI) {
                        result[workspaceID] = path
                        continue
                    }
                    if let pathEntries = entry["paths"] as? [[String: Any]],
                       let uri = pathEntries.first?["uri"] as? [String: Any],
                       let path = stringValue(uri["fsPath"]) ?? stringValue(uri["path"]) {
                        result[workspaceID] = path
                    }
                }
            }
        }
        if let workspaceRoot = paths.workspaceStorageDirectory {
            let fileManager = FileManager.default
            guard let folders = try? fileManager.contentsOfDirectory(
                at: workspaceRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return result }
            for folder in folders {
                let workspaceJSON = folder.appendingPathComponent("workspace.json", isDirectory: false)
                guard let data = try? Data(contentsOf: workspaceJSON),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let folderURI = stringValue(object["folder"]),
                      let path = pathFromFileURI(folderURI)
                else { continue }
                result[folder.lastPathComponent] = path
            }
        }
        return result
    }

    private static func upsert(
        _ conversationID: String,
        path: String?,
        name: String?,
        title: String?,
        into byConversation: inout [String: Mutable]
    ) {
        let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var current = byConversation[key] ?? Mutable()
        if current.projectPath == nil, let path = sanitizedProjectPath(path) {
            current.projectPath = path
        }
        if current.projectName == nil {
            current.projectName = sanitizedProjectName(name) ?? sanitizedProjectName(path)
        }
        if current.title == nil, let title = sanitizedSessionTitle(title) {
            current.title = title
        }
        byConversation[key] = current
    }

    // MARK: - SQLite / JSON helpers

    private static func openReadOnly(_ url: URL) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        return database
    }

    private static func readItem(_ key: String, database: OpaquePointer) -> String? {
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

    private static func parseJSONObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func parseJSONArray(_ string: String) -> [[String: Any]]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func pathFromFileURI(_ value: String) -> String? {
        guard let url = URL(string: value), url.isFileURL else {
            if value.hasPrefix("file://") {
                let dropped = String(value.dropFirst("file://".count))
                return sanitizedProjectPath(dropped.removingPercentEncoding ?? dropped)
            }
            return sanitizedProjectPath(value)
        }
        return sanitizedProjectPath(url.path)
    }

    private static func encodeWorkspaceFolderName(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.replacingOccurrences(of: "/", with: "-")
    }
}
