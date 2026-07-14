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
        #expect(AgentStatus.working.detailText == "WORKING ON TASK")
        #expect(AgentStatus.reviewing.animation == .review)
        #expect(AgentStatus.reviewing.displayText == "Reviewing…")
        #expect(AgentStatus.reviewing.detailText == "REVIEWING CHANGES")
        #expect(AgentStatus.needsApproval.animation == .waiting)
        #expect(AgentStatus.needsApproval.detailText == "WAITING FOR YOU")
        #expect(AgentStatus.finished.animation == .waving)
        #expect(AgentStatus.finished.detailText == "TURN COMPLETE")
        #expect(AgentStatus.failed.animation == .failed)
        #expect(AgentStatus.failed.detailText == "TURN FAILED")
    }

    @Test func displayNamesAreWhitespaceNormalizedAndBounded() {
        let raw = "  Fix\n\t the   monitor   title  " + String(repeating: "x", count: 120)
        let name = AgentSessionDisplayName.sanitized(raw, source: .prompt)

        #expect(name?.value.hasPrefix("Fix the monitor title ") == true)
        #expect(name?.value.count == 96)
        #expect(name?.value.lengthOfBytes(using: .utf8) ?? 0 <= 384)
        #expect(name?.source == .prompt)
    }

    @Test func firstPromptTitlePersistsAcrossStatusUpdates() {
        var store = AgentSessionStore()
        let first = AgentSessionDisplayName.sanitized("Initial task", source: .prompt)!
        let later = AgentSessionDisplayName.sanitized("Later task", source: .prompt)!
        store.upsert(event(provider: .claude, id: "session", status: .working, displayName: first))
        store.upsert(event(provider: .claude, id: "session", status: .reviewing, displayName: later))

        #expect(store.selected?.displayName == first)
        #expect(store.selected?.detailText == "Initial task")
    }

    @Test func nativeProviderTitleOverridesPromptButPromptCannotOverrideIt() {
        var store = AgentSessionStore()
        let key = AgentSessionKey(provider: .cursor, sessionID: "conversation")
        let prompt = AgentSessionDisplayName.sanitized("Prompt title", source: .prompt)!
        let native = AgentSessionDisplayName.sanitized("Cursor title", source: .nativeProvider)!
        store.upsert(event(provider: .cursor, id: "conversation", status: .working, displayName: prompt))

        let didSetNative = store.setDisplayName(native, for: key)
        let didReplaceNativeWithPrompt = store.setDisplayName(prompt, for: key)
        #expect(didSetNative)
        #expect(!didReplaceNativeWithPrompt)
        #expect(store.selected?.displayName == native)
    }

    @Test func everyStatusHasAnAttentionTone() {
        #expect(AgentStatus.working.indicatorTone == .yellow)
        #expect(AgentStatus.reviewing.indicatorTone == .cyan)
        #expect(AgentStatus.needsApproval.indicatorTone == .violet)
        #expect(AgentStatus.finished.indicatorTone == .green)
        #expect(AgentStatus.failed.indicatorTone == .red)
    }

    private func event(
        provider: AgentProvider,
        id: String,
        status: AgentStatus,
        displayName: AgentSessionDisplayName? = nil
    ) -> NormalizedAgentEvent {
        NormalizedAgentEvent(provider: provider, sessionID: id, status: status, displayName: displayName)
    }
}
