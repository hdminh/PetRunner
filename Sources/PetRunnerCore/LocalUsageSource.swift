import CryptoKit
import Foundation

public enum LocalUsageSource {
    /// Bump when Claude/Codex JSONL → ledger mapping changes so receipts
    /// invalidate and UsageCoordinator can rebuild provider rows cleanly.
    /// Includes the active pricing catalog version so remote rate refreshes
    /// also force a cost rebuild on the next usage scan.
    public static var historicalParserRevision: String {
        "historical-sessions-v4+\(BundledPricing.version)"
    }

    public static func codexRecords(root: URL, now: Date = .now) -> [AgentUsageRecord] {
        codexScan(root: root, now: now).records
    }

    public static func claudeRecords(roots: [URL], now: Date = .now) -> [AgentUsageRecord] {
        claudeScan(roots: roots, now: now).records
    }

    /// Finds the standard Claude Code projects directory, or an explicit
    /// comma-separated `CLAUDE_CONFIG_DIR` override. The explicit-root overload
    /// remains available for app configuration and tests.
    public static func claudeRecords(now: Date = .now, environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentUsageRecord] {
        claudeScan(roots: resolvedClaudeRoots(environment: environment, homeDirectory: homeDirectory), now: now).records
    }

    public static func resolvedClaudeRoots(environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let roots: [URL]
        if let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            roots = configured.split(separator: ",").map { raw in
                let url = URL(fileURLWithPath: String(raw).trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL
                return url.lastPathComponent == "projects" ? url : url.appendingPathComponent("projects", isDirectory: true)
            }
        } else {
            roots = [
                homeDirectory.appendingPathComponent(".config/claude/projects", isDirectory: true),
                homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
            ]
        }
        return uniqueRoots(roots)
    }

    /// Kept as a source-compatible no-op while Cursor accounting moves to its
    /// authenticated usage-events connector. Local SQLite context values are
    /// not authoritative token or cost records and must never reach the ledger.
    @available(*, deprecated, message: "Use the authenticated Cursor usage-events connector.")
    public static func cursorEstimatedRecords(databaseURL: URL, now: Date = .now) -> [AgentUsageRecord] {
        []
    }

    public static func codexSourceFiles(root: URL) -> [URL] {
        // ccusage / CodexBar: scan live + archived, but never bill the same
        // rollout basename twice when Codex copies a session into archived_sessions.
        let live = jsonlFiles(in: root.appendingPathComponent("sessions", isDirectory: true))
        let archived = jsonlFiles(in: root.appendingPathComponent("archived_sessions", isDirectory: true))
        var byBasename: [String: URL] = [:]
        for file in archived + live {
            byBasename[file.lastPathComponent.lowercased()] = file
        }
        return uniqueFiles(Array(byBasename.values))
    }

    public static func claudeSourceFiles(roots: [URL]) -> [URL] {
        uniqueFiles(uniqueRoots(roots).flatMap { jsonlFiles(in: $0) })
    }

    public static func sourceReceipts(for files: [URL], parserRevision: String = historicalParserRevision) -> [HistoricalUsageSourceReceipt] {
        uniqueFiles(files).compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let modifiedAt = values.contentModificationDate else { return nil }
            return .init(sourceKey: sourceIdentity(for: file), fileSize: Int64(values.fileSize ?? 0), modifiedAt: modifiedAt, parserRevision: parserRevision)
        }
    }

    public static func sourceIdentity(for file: URL) -> String {
        SHA256.hash(data: Data(file.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func codexScan(root: URL, now: Date = .now) -> HistoricalUsageScan {
        codexScan(files: codexSourceFiles(root: root), now: now)
    }

    public static func codexScan(files: [URL], now: Date = .now) -> HistoricalUsageScan {
        combine(files.map { parseCodex(file: $0, fallbackDate: fallbackDate(for: $0, now: now)) }, receipts: sourceReceipts(for: files))
    }

    public static func claudeScan(roots: [URL], now: Date = .now) -> HistoricalUsageScan {
        claudeScan(files: claudeSourceFiles(roots: roots), now: now)
    }

    public static func claudeScan(files: [URL], now: Date = .now) -> HistoricalUsageScan {
        combine(files.map { parseClaude(file: $0, fallbackDate: fallbackDate(for: $0, now: now)) }, receipts: sourceReceipts(for: files))
    }

    private static func parseCodex(file: URL, fallbackDate: Date) -> HistoricalUsageScan {
        var sessionID = file.deletingPathExtension().lastPathComponent
        var projectName: String?
        var projectPath: String?
        var title: String?
        var model: String?
        var startedAt = fallbackDate
        var lastActivityAt = fallbackDate
        var sawEvent = false
        var previousTotal: UsageTokenBreakdown?
        var records: [AgentUsageRecord] = []

        forEachJSONObject(in: file) { line, object in
            let payload = object["payload"] as? [String: Any] ?? [:]
            let occurredAt = date(object["timestamp"]) ?? date(payload["timestamp"]) ?? fallbackDate
            if !sawEvent {
                startedAt = occurredAt
                lastActivityAt = occurredAt
                sawEvent = true
            } else {
                lastActivityAt = max(lastActivityAt, occurredAt)
            }
            if model == nil { model = modelName(in: payload) }
            let recordType = string(object["type"]) ?? (string(payload["type"]) == "token_count" ? "event_msg" : nil)
            switch recordType {
            case "session_meta":
                sessionID = string(payload["id"]) ?? sessionID
                if let cwd = string(payload["cwd"]) {
                    projectPath = sanitizedProjectPath(cwd) ?? projectPath
                    projectName = sanitizedProjectName(cwd) ?? projectName
                }
                if let timestamp = date(payload["timestamp"]) { startedAt = min(startedAt, timestamp) }
            case "turn_context":
                if let cwd = string(payload["cwd"]) {
                    projectPath = sanitizedProjectPath(cwd) ?? projectPath
                    projectName = sanitizedProjectName(cwd) ?? projectName
                }
                model = string(payload["model"]) ?? model
            case "event_msg":
                guard let eventType = string(payload["type"]) else { return }
                if eventType == "user_message" {
                    if title == nil, let candidate = messageText(payload), !isSyntheticUserText(candidate) { title = candidate }
                    return
                }
                guard eventType == "token_count", let info = payload["info"] as? [String: Any] else { return }
                let totals = info["total_token_usage"] as? [String: Any]
                let last = info["last_token_usage"] as? [String: Any]
                let delta: UsageTokenBreakdown?
                if let totals {
                    let current = tokenBreakdown(totals)
                    delta = cumulativeDelta(current, previous: previousTotal)
                    previousTotal = maximum(previousTotal ?? .init(), current)
                } else if let last {
                    let current = tokenBreakdown(last)
                    delta = current.total > 0 ? current : nil
                    previousTotal = add(previousTotal ?? .init(), current)
                } else { delta = nil }
                guard let delta, delta.total > 0 else { return }
                let recordModel = modelName(in: info) ?? model
                records.append(.init(id: "codex:\(sessionID):\(line)", provider: .codex, sessionID: sessionID, occurredAt: occurredAt, model: recordModel, tokens: delta, cost: BundledPricing.cost(model: recordModel, tokens: delta, occurredAt: occurredAt)))
            default: break
            }
        }
        let session = HistoricalUsageSession(provider: .codex, sessionID: sessionID, projectName: projectName, title: title, startedAt: startedAt, lastActivityAt: lastActivityAt, model: model, projectPath: projectPath)
        return .init(records: records, sessions: sawEvent ? [session] : [])
    }

    private static func parseClaude(file: URL, fallbackDate: Date) -> HistoricalUsageScan {
        let parentSessionID = parentSessionID(fromSubagentPath: file.path)
        var sessionID = parentSessionID ?? file.deletingPathExtension().lastPathComponent
        var projectName: String?
        var projectPath: String?
        var title: String?
        var hasAITitle = false
        var model: String?
        var startedAt = fallbackDate
        var lastActivityAt = fallbackDate
        var sawEvent = false
        // Claude Code streams multiple assistant JSONL rows per API response that
        // share message.id + requestId. ccgauge keeps the earliest row for usage/cost
        // (`dedupAssistantRecords` earliest-wins). Keying on uuid over-bills input.
        var keyedRecords: [String: AgentUsageRecord] = [:]
        var unkeyedRecords: [AgentUsageRecord] = []

        forEachJSONObject(in: file) { line, object in
            let occurredAt = date(object["timestamp"]) ?? fallbackDate
            if !sawEvent {
                startedAt = occurredAt
                lastActivityAt = occurredAt
                sawEvent = true
            } else {
                lastActivityAt = max(lastActivityAt, occurredAt)
            }
            let objectSessionID = sessionIdentifier(in: object) ?? sessionIdentifier(in: object["message"] as? [String: Any])
            if parentSessionID == nil { sessionID = objectSessionID ?? sessionID }
            if let cwd = string(object["cwd"]) {
                projectPath = sanitizedProjectPath(cwd) ?? projectPath
                projectName = sanitizedProjectName(cwd) ?? projectName
            }
            let type = string(object["type"])
            if parentSessionID == nil, type == "ai-title", let candidate = string(object["aiTitle"]) ?? string(object["title"]) ?? messageText(object) {
                title = candidate; hasAITitle = true
                return
            }
            if parentSessionID == nil, type == "user", title == nil, !hasAITitle, let candidate = messageText(object), !isSyntheticUserText(candidate), !candidate.isEmpty {
                title = candidate
                return
            }
            guard type == "assistant", let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return }
            let cacheCreation = int(usage["cache_creation_input_tokens"])
            let cacheCreation1h = min(cacheCreation, int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]))
            let tokens = UsageTokenBreakdown(input: int(usage["input_tokens"]), cachedInput: int(usage["cache_read_input_tokens"]), cacheCreation: cacheCreation, cacheCreation1h: cacheCreation1h, output: int(usage["output_tokens"]))
            guard tokens.total > 0 else { return }
            let recordModel = string(message["model"]); model = recordModel ?? model
            let messageID = string(message["id"])
            let requestID = string(object["requestId"])
            let sourceID: String
            let dedupeKey: String?
            if let messageID, let requestID {
                sourceID = "\(messageID):\(requestID)"
                dedupeKey = sourceID
            } else if let messageID {
                // Third-party / older transports omit requestId; message.id alone
                // still collapses repeated JSONL rewrites (ccusage #985).
                sourceID = "mid:\(messageID)"
                dedupeKey = sourceID
            } else if let requestID {
                sourceID = "req:\(requestID)"
                dedupeKey = sourceID
            } else {
                sourceID = string(object["uuid"]) ?? "\(occurredAt.timeIntervalSince1970):\(line)"
                dedupeKey = nil
            }
            let record = AgentUsageRecord(
                id: "claude:\(sessionID):\(sourceID)",
                provider: .claude,
                sessionID: sessionID,
                occurredAt: occurredAt,
                model: recordModel,
                tokens: tokens,
                cost: BundledPricing.cost(model: recordModel, tokens: tokens, occurredAt: occurredAt)
            )
            if let dedupeKey {
                // ccgauge earliest-wins: keep the first/earliest timestamp for cost.
                if let existing = keyedRecords[dedupeKey] {
                    if record.occurredAt < existing.occurredAt {
                        keyedRecords[dedupeKey] = record
                    }
                } else {
                    keyedRecords[dedupeKey] = record
                }
            } else {
                unkeyedRecords.append(record)
            }
        }
        let records = Array(keyedRecords.values) + unkeyedRecords
        let session = HistoricalUsageSession(provider: .claude, sessionID: sessionID, projectName: projectName, title: title, startedAt: startedAt, lastActivityAt: lastActivityAt, model: model, projectPath: projectPath)
        return .init(records: records, sessions: sawEvent ? [session] : [])
    }

    private static func jsonlFiles(in root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]))?.flatMap { url -> [URL] in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { return [] }
            if values.isDirectory == true { return jsonlFiles(in: url) }
            return values.isRegularFile == true && url.pathExtension == "jsonl" ? [url] : []
        } ?? []
    }

    private static func uniqueFiles(_ files: [URL]) -> [URL] {
        var paths: Set<String> = []
        return files.map(\.standardizedFileURL).filter {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true && paths.insert($0.path).inserted
        }.sorted { $0.path < $1.path }
    }

    private static func uniqueRoots(_ roots: [URL]) -> [URL] {
        var paths: Set<String> = []
        return roots.map(\.standardizedFileURL).filter { paths.insert($0.path).inserted }
    }
    private static func fallbackDate(for file: URL, now: Date) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
    }
    private static func counterDelta(_ current: Int, previous: Int) -> Int {
        max(current - previous, 0)
    }

    private static func combine(_ scans: [HistoricalUsageScan], receipts: [HistoricalUsageSourceReceipt]) -> HistoricalUsageScan {
        var records: [AgentUsageRecord] = []
        var recordIndexes: [String: Int] = [:]
        var sessions: [String: HistoricalUsageSession] = [:]
        for scan in scans {
            for record in scan.records {
                if let index = recordIndexes[record.id] {
                    records[index] = record
                } else {
                    recordIndexes[record.id] = records.count
                    records.append(record)
                }
            }
            for session in scan.sessions {
                let key = session.id
                guard let existing = sessions[key] else { sessions[key] = session; continue }
                let useIncoming = session.lastActivityAt > existing.lastActivityAt
                sessions[key] = .init(provider: session.provider, sessionID: session.sessionID, projectName: existing.projectName ?? session.projectName, title: existing.title ?? session.title, startedAt: min(existing.startedAt, session.startedAt), lastActivityAt: max(existing.lastActivityAt, session.lastActivityAt), model: useIncoming ? session.model ?? existing.model : existing.model ?? session.model, sourceRevision: useIncoming ? session.sourceRevision : existing.sourceRevision, projectPath: existing.projectPath ?? session.projectPath)
            }
        }
        return .init(records: records, sessions: sessions.values.sorted { $0.lastActivityAt > $1.lastActivityAt }, sourceReceipts: receipts)
    }

    private static func forEachJSONObject(in file: URL, _ body: (Int, [String: Any]) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let maxLineBytes = 512 * 1024
        var pending = Data()
        var lineNumber = 0
        var discardUntilNewline = false
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                lineNumber += 1
                if discardUntilNewline { discardUntilNewline = false; continue }
                guard line.count <= maxLineBytes, let object = try? JSONSerialization.jsonObject(with: line), let dictionary = object as? [String: Any] else { continue }
                body(lineNumber, dictionary)
            }
            if pending.count > maxLineBytes { pending.removeAll(keepingCapacity: true); discardUntilNewline = true }
        }
        if !pending.isEmpty, !discardUntilNewline, pending.count <= maxLineBytes, let object = try? JSONSerialization.jsonObject(with: pending), let dictionary = object as? [String: Any] {
            body(lineNumber + 1, dictionary)
        }
    }

    private static func cumulativeDelta(_ current: UsageTokenBreakdown, previous: UsageTokenBreakdown?) -> UsageTokenBreakdown? {
        guard let previous else { return current.total > 0 ? current : nil }
        let delta = UsageTokenBreakdown(input: counterDelta(current.input, previous: previous.input), cachedInput: counterDelta(current.cachedInput, previous: previous.cachedInput), cacheCreation: counterDelta(current.cacheCreation, previous: previous.cacheCreation), output: counterDelta(current.output, previous: previous.output), reasoning: counterDelta(current.reasoning, previous: previous.reasoning))
        return delta.total > 0 ? delta : nil
    }

    private static func add(_ lhs: UsageTokenBreakdown, _ rhs: UsageTokenBreakdown) -> UsageTokenBreakdown {
        .init(input: lhs.input + rhs.input, cachedInput: lhs.cachedInput + rhs.cachedInput, cacheCreation: lhs.cacheCreation + rhs.cacheCreation, cacheCreation1h: lhs.cacheCreation1h + rhs.cacheCreation1h, output: lhs.output + rhs.output, reasoning: lhs.reasoning + rhs.reasoning)
    }

    private static func maximum(_ lhs: UsageTokenBreakdown, _ rhs: UsageTokenBreakdown) -> UsageTokenBreakdown {
        .init(input: max(lhs.input, rhs.input), cachedInput: max(lhs.cachedInput, rhs.cachedInput), cacheCreation: max(lhs.cacheCreation, rhs.cacheCreation), cacheCreation1h: max(lhs.cacheCreation1h, rhs.cacheCreation1h), output: max(lhs.output, rhs.output), reasoning: max(lhs.reasoning, rhs.reasoning))
    }

    private static func tokenBreakdown(_ usage: [String: Any]) -> UsageTokenBreakdown {
        .init(input: int(usage["input_tokens"]), cachedInput: int(usage["cached_input_tokens"]), cacheCreation: int(usage["cache_creation_input_tokens"]), output: int(usage["output_tokens"]), reasoning: int(usage["reasoning_output_tokens"]))
    }

    private static func messageText(_ dictionary: [String: Any]) -> String? {
        if let message = dictionary["message"] as? String { return message }
        if let content = dictionary["content"] as? String { return content }
        if let message = dictionary["message"] as? [String: Any] { return messageText(message) }
        if let content = dictionary["content"] as? [Any] {
            for item in content {
                if let text = (item as? [String: Any]).flatMap({ string($0["text"]) ?? string($0["content"]) }) { return text }
            }
        }
        return nil
    }

    private static func isSyntheticUserText(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("Base directory for this skill:") || text.hasPrefix("<system-reminder>") || text.hasPrefix("Caveat: The messages below were generated by") || text.hasPrefix("<task-notification>")
    }

    private static func parentSessionID(fromSubagentPath path: String) -> String? {
        let pattern = #"[\\/]([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[\\/]subagents[\\/](?:[^\\/]+[\\/])*agent-[^\\/]+\.jsonl$"#
        guard let range = path.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = String(path[range])
        return match.split(whereSeparator: { $0 == "/" || $0 == "\\" }).first.map(String.init)
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    private static func string(_ value: Any?) -> String? { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    private static func modelName(in dictionary: [String: Any]?) -> String? {
        guard let dictionary else { return nil }
        return (dictionary["model"] as? String) ?? (dictionary["model_name"] as? String) ?? (dictionary["modelName"] as? String)
    }
    private static func sessionIdentifier(in dictionary: [String: Any]?) -> String? {
        guard let dictionary else { return nil }
        return (dictionary["conversation_id"] as? String) ?? (dictionary["session_id"] as? String) ?? (dictionary["sessionId"] as? String)
    }
    private static func date(_ value: Any?) -> Date? { guard let string = value as? String else { return nil }; return ISO8601DateFormatter().date(from: string) }
}
