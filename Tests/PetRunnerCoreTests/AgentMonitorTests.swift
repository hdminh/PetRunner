@testable import PetRunnerCore
import Testing

struct AgentMonitorTests {
    @Test func insertsOneSelectedSessionWithItsAnimation() {
        var store = AgentSessionStore()
        store.upsert(event(provider: .codex, id: "session-a", status: .working))

        #expect(store.entries.count == 1)
        #expect(store.selected?.provider == .codex)
        #expect(store.selected?.sessionID == "session-a")
        #expect(store.selected?.status == .working)
        #expect(store.selected?.animation == .running)
        #expect(store.selectedIndex == 0)
    }

    @Test func updatesOneSessionWithoutCreatingHistory() {
        var store = AgentSessionStore()
        store.upsert(event(provider: .claude, id: "session-a", status: .working))
        store.upsert(event(provider: .claude, id: "session-a", status: .needsApproval))

        #expect(store.entries.count == 1)
        #expect(store.selected?.status == .needsApproval)
        #expect(store.selected?.displayText == "Needs approval")
        #expect(store.selected?.animation == .waiting)
    }

    @Test func updatingSessionMovesItToMostRecentPosition() {
        var store = AgentSessionStore()
        store.upsert(event(provider: .codex, id: "a", status: .working))
        store.upsert(event(provider: .claude, id: "b", status: .reviewing))
        store.upsert(event(provider: .cursor, id: "c", status: .finished))
        store.upsert(event(provider: .codex, id: "a", status: .failed))

        #expect(store.entries.map(\.sessionID) == ["a", "c", "b"])
        #expect(store.selected?.status == .failed)
        #expect(store.selectedIndex == 0)
    }

    @Test func keepsOnlyFiveMostRecentlyAcceptedSessions() {
        var store = AgentSessionStore()
        for index in 0..<6 {
            store.upsert(event(provider: .codex, id: "session-\(index)", status: .working))
        }

        #expect(store.entries.map(\.sessionID) == ["session-5", "session-4", "session-3", "session-2", "session-1"])
        #expect(store.entries.count == AgentSessionStore.maximumEntries)
    }

    @Test func navigationClampsWithoutReorderingEntries() {
        var store = AgentSessionStore()
        for id in ["a", "b", "c"] {
            store.upsert(event(provider: .codex, id: id, status: .working))
        }
        let order = store.entries.map(\.sessionID)

        store.selectNext()
        #expect(store.selectedIndex == 1)
        store.selectNext()
        #expect(store.selectedIndex == 2)
        store.selectNext()
        #expect(store.selectedIndex == 2)
        store.selectPrevious()
        #expect(store.selectedIndex == 1)
        #expect(store.entries.map(\.sessionID) == order)
    }

    @Test func directSelectionChangesOnlyTheSelectedSession() {
        var store = AgentSessionStore()
        store.upsert(event(provider: .codex, id: "oldest", status: .working))
        store.upsert(event(provider: .claude, id: "middle", status: .reviewing))
        store.upsert(event(provider: .cursor, id: "newest", status: .needsApproval))
        let order = store.entries.map(\.sessionID)

        let didSelectMiddle = store.select(at: 1)
        #expect(didSelectMiddle)
        #expect(store.selected?.provider == .claude)
        #expect(store.selected?.sessionID == "middle")
        #expect(store.entries.map(\.sessionID) == order)

        let didSelectNegative = store.select(at: -1)
        let didSelectPastEnd = store.select(at: 3)
        #expect(!didSelectNegative)
        #expect(!didSelectPastEnd)
        #expect(store.selectedIndex == 1)
        #expect(store.entries.map(\.sessionID) == order)
    }

    @Test func removesOneTerminalSessionWithoutDisturbingOtherActiveSessions() {
        var store = AgentSessionStore()
        let active = NormalizedAgentEvent(provider: .codex, sessionID: "active", status: .working)
        let terminal = NormalizedAgentEvent(provider: .claude, sessionID: "done", status: .finished)
        store.upsert(active)
        store.upsert(terminal)

        let removed = store.remove(terminal.key)
        #expect(removed)
        #expect(store.entries.map(\.sessionID) == ["active"])
        #expect(store.selected?.status == .working)
    }

    @Test func removingAnotherSessionPreservesTheSessionTheUserSelected() {
        var store = AgentSessionStore()
        let oldest = NormalizedAgentEvent(provider: .codex, sessionID: "oldest", status: .working)
        let selected = NormalizedAgentEvent(provider: .claude, sessionID: "selected", status: .needsApproval)
        let newest = NormalizedAgentEvent(provider: .cursor, sessionID: "newest", status: .reviewing)
        store.upsert(oldest)
        store.upsert(selected)
        store.upsert(newest)
        store.selectNext()

        let removed = store.remove(newest.key)

        #expect(removed)
        #expect(store.selected?.sessionID == "selected")
        #expect(store.entries.map(\.sessionID) == ["selected", "oldest"])
    }

    @Test func newActivitySnapsSelectionBackToUpdatedTopSession() {
        var store = AgentSessionStore()
        store.upsert(event(provider: .codex, id: "a", status: .working))
        store.upsert(event(provider: .claude, id: "b", status: .reviewing))
        store.selectNext()
        store.upsert(event(provider: .codex, id: "a", status: .finished))

        #expect(store.entries.map(\.sessionID) == ["a", "b"])
        #expect(store.selectedIndex == 0)
        #expect(store.selected?.status == .finished)
    }

    @Test func everyStatusUsesExistingAnimationAndFixedText() {
        #expect(AgentStatus.working.animation == .running)
        #expect(AgentStatus.working.displayText == "Working…")
        #expect(AgentStatus.reviewing.animation == .review)
        #expect(AgentStatus.reviewing.displayText == "Reviewing…")
        #expect(AgentStatus.needsApproval.animation == .waiting)
        #expect(AgentStatus.finished.animation == .waving)
        #expect(AgentStatus.failed.animation == .failed)
    }

    @Test func sessionLabelsAreStableAndNeverExposeRawSessionIDs() {
        let key = AgentSessionKey(provider: .codex, sessionID: "secret-session-id")

        let first = AgentSessionLabel.labels(for: [key])[key]
        let second = AgentSessionLabel.labels(for: [key])[key]

        #expect(first == second)
        #expect(first?.hasPrefix("SESSION ") == true)
        #expect(first?.contains("secret-session-id") == false)
    }

    @Test func sessionLabelsExtendOnlyCollidingPrefixes() {
        let first = AgentSessionKey(provider: .codex, sessionID: "first")
        let second = AgentSessionKey(provider: .claude, sessionID: "second")
        let third = AgentSessionKey(provider: .cursor, sessionID: "third")
        let fingerprints = [
            first: "ABCDEF123456",
            second: "ABCDEF654321",
            third: "987654321ABC",
        ]

        let labels = AgentSessionLabel.labels(for: [first, second, third]) { fingerprints[$0]! }

        #expect(labels[first] == "SESSION ABCDEF12")
        #expect(labels[second] == "SESSION ABCDEF65")
        #expect(labels[third] == "SESSION 987654")
    }

    @Test func sessionLabelsStayStableWhenFullFingerprintsCollide() {
        let first = AgentSessionKey(provider: .codex, sessionID: "first")
        let second = AgentSessionKey(provider: .claude, sessionID: "second")

        let firstOrder = AgentSessionLabel.labels(for: [first, second]) { _ in "ABCDEF" }
        let secondOrder = AgentSessionLabel.labels(for: [second, first]) { _ in "ABCDEF" }

        #expect(firstOrder[first] == secondOrder[first])
        #expect(firstOrder[second] == secondOrder[second])
    }

    @Test func everyStatusHasAnAttentionTone() {
        #expect(AgentStatus.working.indicatorTone == .yellow)
        #expect(AgentStatus.reviewing.indicatorTone == .cyan)
        #expect(AgentStatus.needsApproval.indicatorTone == .violet)
        #expect(AgentStatus.finished.indicatorTone == .green)
        #expect(AgentStatus.failed.indicatorTone == .red)
    }

    private func event(provider: AgentProvider, id: String, status: AgentStatus) -> NormalizedAgentEvent {
        NormalizedAgentEvent(provider: provider, sessionID: id, status: status)
    }
}
