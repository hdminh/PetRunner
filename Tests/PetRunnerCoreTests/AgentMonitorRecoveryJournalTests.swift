@testable import PetRunnerCore
import Foundation
import Testing

struct AgentMonitorRecoveryJournalTests {
    @Test func recoversActiveSessionsInStableOldestToNewestInsertionOrder() throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = AgentMonitorRecoveryJournal(url: url)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        try journal.record(event(id: "oldest", status: .working), at: start)
        try journal.record(event(id: "newest", status: .reviewing), at: start.addingTimeInterval(10))

        #expect(try journal.recoveredEvents(at: start.addingTimeInterval(20)).map(\.sessionID) == ["oldest", "newest"])
    }

    @Test func removesTerminalAndExpiredSessions() throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = AgentMonitorRecoveryJournal(url: url)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        try journal.record(event(id: "done", status: .working), at: start)
        try journal.record(event(id: "done", status: .finished), at: start.addingTimeInterval(1))
        try journal.record(event(id: "stale", status: .working), at: start)

        #expect(try journal.recoveredEvents(at: start.addingTimeInterval(AgentMonitorRecoveryJournal.maximumAge + 1)).isEmpty)
    }

    @Test func retainsAllActiveSessionsAndOnlyDerivedFields() throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = AgentMonitorRecoveryJournal(url: url)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        for index in 0...5 {
            try journal.record(event(id: "session-\(index)", status: .working), at: start.addingTimeInterval(Double(index)))
        }

        let recovered = try journal.recoveredEvents(at: start.addingTimeInterval(10))
        #expect(recovered.map(\.sessionID) == ["session-0", "session-1", "session-2", "session-3", "session-4", "session-5"])
        let data = try Data(contentsOf: url)
        #expect(String(data: data, encoding: .utf8)?.contains("tool_input") == false)
        #expect(String(data: data, encoding: .utf8)?.contains("prompt") == false)
    }

    @Test func treatsMalformedOrNonPrivateJournalsAsEmpty() throws {
        let url = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let journal = AgentMonitorRecoveryJournal(url: url)

        #expect(try journal.recoveredEvents().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try journal.recoveredEvents().isEmpty)
    }

    private func event(id: String, status: AgentStatus) -> NormalizedAgentEvent {
        NormalizedAgentEvent(
            provider: .codex,
            sessionID: id,
            status: status,
            model: AgentSessionModel.sanitized("gpt-5.2-codex"),
            activity: AgentActivity.sanitized("Reading server.swift")
        )
    }

    private func temporaryJournalURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("petrunner-journal-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sessions.json", isDirectory: false)
    }
}
