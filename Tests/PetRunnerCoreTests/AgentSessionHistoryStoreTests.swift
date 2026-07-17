@testable import PetRunnerCore
import Foundation
import Testing

struct AgentSessionHistoryStoreTests {
    @Test func recordsOneSummaryAndOnlySemanticTimelineChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentSessionHistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let model = AgentSessionModel.sanitized("claude-sonnet-4-5")!
        let activity = AgentActivity.sanitized("Reading monitor state")!
        let name = AgentSessionName.sanitized("Dashboard redesign")!
        let cost = AgentSessionEstimatedCost(usd: Decimal(string: "0.25")!)!
        let working = NormalizedAgentEvent(
            provider: .claude,
            sessionID: "private-session-id",
            status: .working,
            model: model,
            activity: activity,
            sessionName: name,
            estimatedCost: cost
        )

        #expect(try store.record(working, at: startedAt))
        #expect(!(try store.record(working, at: startedAt.addingTimeInterval(1))))
        #expect(try store.record(
            NormalizedAgentEvent(provider: .claude, sessionID: "private-session-id", status: .finished),
            at: startedAt.addingTimeInterval(2)
        ))

        let summaries = try store.summaries(at: startedAt.addingTimeInterval(3))
        #expect(summaries.count == 1)
        #expect(summaries[0].provider == .claude)
        #expect(summaries[0].model == model)
        #expect(summaries[0].sessionName == name)
        #expect(summaries[0].estimatedCost == cost)
        #expect(summaries[0].status == .finished)
        #expect(summaries[0].firstSeenAt == startedAt)
        #expect(summaries[0].finishedAt == startedAt.addingTimeInterval(2))

        let timeline = try store.timeline(for: summaries[0].id)
        #expect(timeline.map(\.status) == [.working, .finished])
        #expect(timeline[1].model == model)
        #expect(timeline[1].estimatedCost == cost)
    }

    @Test func filtersPrunesAndClearsPrivateHistory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentSessionHistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let old = now.addingTimeInterval(-AgentSessionHistoryStore.defaultMaximumAge - 1)
        let model = AgentSessionModel.sanitized("gpt-5")!
        let activity = AgentActivity.sanitized("Running tests")!

        _ = try store.record(NormalizedAgentEvent(provider: .claude, sessionID: "old", status: .working), at: old)
        _ = try store.record(
            NormalizedAgentEvent(provider: .codex, sessionID: "recent", status: .reviewing, model: model, activity: activity),
            at: now
        )

        let filtered = try store.summaries(
            matching: AgentSessionHistoryQuery(provider: .codex, model: model, searchText: "tests", startDate: now.addingTimeInterval(-60)),
            at: now
        )
        #expect(filtered.count == 1)
        #expect(filtered[0].activity == activity)
        #expect(try store.summaries(at: now).count == 1)

        try store.clear()
        #expect(try store.summaries(at: now).isEmpty)
    }

    @Test func doesNotReplaceAnUnreadableHistoryLocation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFile = root.appendingPathComponent("blocked")
        try Data("keep".utf8).write(to: blockingFile)

        #expect(throws: Error.self) {
            try AgentSessionHistoryStore(url: blockingFile.appendingPathComponent("history.sqlite"))
        }
        #expect(try Data(contentsOf: blockingFile) == Data("keep".utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petrunner-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
