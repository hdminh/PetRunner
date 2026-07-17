@testable import PetRunnerCore
import Foundation
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

    @Test func updatingSessionKeepsItsCreationPosition() {
        var store = AgentSessionStore()
        store.upsert(event(provider: .codex, id: "a", status: .working))
        store.upsert(event(provider: .claude, id: "b", status: .reviewing))
        store.upsert(event(provider: .cursor, id: "c", status: .finished))
        store.upsert(event(provider: .codex, id: "a", status: .failed))

        #expect(store.entries.map(\.sessionID) == ["c", "b", "a"])
        #expect(store.selected?.status == .failed)
        #expect(store.selectedIndex == 2)
    }

    @Test func retainsMoreThanFiveSessionsInNewestFirstOrder() {
        var store = AgentSessionStore()
        for index in 0..<6 {
            store.upsert(event(provider: .codex, id: "session-\(index)", status: .working))
        }

        #expect(store.entries.map(\.sessionID) == ["session-5", "session-4", "session-3", "session-2", "session-1", "session-0"])
        #expect(store.entries.count == 6)
    }

    @Test func navigationClampsWithoutReorderingEntries() {
        var store = AgentSessionStore()
        for id in ["a", "b", "c"] {
            store.upsert(event(provider: .codex, id: id, status: .working))
        }
        let order = store.entries.map(\.sessionID)
        let selectedNewest = store.select(at: 0)
        #expect(selectedNewest)

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
        let didSelectMiddle = store.select(at: 1)
        #expect(didSelectMiddle)

        let removed = store.remove(newest.key)

        #expect(removed)
        #expect(store.selected?.sessionID == "selected")
        #expect(store.entries.map(\.sessionID) == ["selected", "oldest"])
    }

    @Test func newSessionAndActivityPreserveTheSelectedSession() {
        var store = AgentSessionStore()
        store.upsert(event(provider: .codex, id: "a", status: .working))
        store.upsert(event(provider: .claude, id: "b", status: .reviewing))
        #expect(store.selected?.sessionID == "a")
        store.upsert(event(provider: .cursor, id: "c", status: .working))
        #expect(store.selected?.sessionID == "a")
        #expect(store.selectedIndex == 2)
        store.upsert(event(provider: .codex, id: "a", status: .finished))

        #expect(store.entries.map(\.sessionID) == ["c", "b", "a"])
        #expect(store.selectedIndex == 2)
        #expect(store.selected?.status == .finished)
    }

    @Test func newSessionsDoNotEvictTheSelectedOldestSession() {
        var store = AgentSessionStore()
        for index in 0..<5 {
            store.upsert(event(provider: .codex, id: "session-\(index)", status: .working))
        }
        #expect(store.selected?.sessionID == "session-0")

        store.upsert(event(provider: .claude, id: "session-5", status: .reviewing))

        #expect(store.entries.map(\.sessionID) == ["session-5", "session-4", "session-3", "session-2", "session-1", "session-0"])
        #expect(store.selected?.sessionID == "session-0")
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

    @Test func activityIsWhitespaceNormalizedBoundedAndPreferredOverFixedStatus() {
        var store = AgentSessionStore()
        let activity = AgentActivity.sanitized("  Reading\n\t  monitor.swift  ")!
        store.upsert(event(provider: .claude, id: "session", status: .working, activity: activity))

        #expect(store.selected?.activity == activity)
        #expect(store.selected?.detailText == "Reading monitor.swift")
        let noActivity = event(provider: .claude, id: "session", status: .reviewing)
        store.upsert(noActivity)
        #expect(store.selected?.activity == activity)
    }

    @Test func modelPersistsUntilAnUpdatedModelArrives() {
        var store = AgentSessionStore()
        let firstModel = AgentSessionModel.sanitized("claude-sonnet-4-5")!
        let updatedModel = AgentSessionModel.sanitized("claude-opus-4-6")!

        store.upsert(event(provider: .claude, id: "session", status: .working, model: firstModel))
        store.upsert(event(provider: .claude, id: "session", status: .reviewing))
        #expect(store.selected?.model == firstModel)

        store.upsert(event(provider: .claude, id: "session", status: .working, model: updatedModel))
        #expect(store.selected?.model == updatedModel)
    }

    @Test func keepsBoundedSessionMetadataWhenLaterEventsOmitIt() {
        var store = AgentSessionStore()
        let name = AgentSessionName.sanitized("  Monitor   UI redesign  ")!
        let cost = AgentSessionEstimatedCost(usd: Decimal(string: "0.004")!)!
        store.upsert(NormalizedAgentEvent(provider: .claude, sessionID: "session", status: .working, sessionName: name, estimatedCost: cost))
        store.upsert(event(provider: .claude, id: "session", status: .reviewing))

        #expect(store.selected?.sessionName == name)
        #expect(store.selected?.estimatedCost == cost)
        #expect(cost.displayText == "<$0.01")
        #expect(AgentSessionEstimatedCost(usd: Decimal(string: "-0.01")!) == nil)
    }

    @Test func providersUseTheirDistinctiveHeaderColors() {
        #expect(AgentProvider.claude.headerColor == ProviderHeaderColor(red: 0.85, green: 0.40, blue: 0.25))
        #expect(AgentProvider.codex.headerColor == ProviderHeaderColor(red: 0.06, green: 0.64, blue: 0.50))
        #expect(AgentProvider.cursor.headerColor == ProviderHeaderColor(red: 0.23, green: 0.51, blue: 0.96))
    }

    @Test func duplicateActivityDoesNotChangeTheStore() {
        var store = AgentSessionStore()
        let activity = AgentActivity.sanitized("Running swift")!
        let first = store.upsert(event(provider: .cursor, id: "conversation", status: .working, activity: activity))
        let duplicate = store.upsert(event(provider: .cursor, id: "conversation", status: .working, activity: activity))

        #expect(first)
        #expect(!duplicate)
    }

    @Test func everyStatusHasAnAttentionTone() {
        #expect(AgentStatus.working.indicatorTone == .yellow)
        #expect(AgentStatus.reviewing.indicatorTone == .cyan)
        #expect(AgentStatus.needsApproval.indicatorTone == .violet)
        #expect(AgentStatus.finished.indicatorTone == .green)
        #expect(AgentStatus.failed.indicatorTone == .red)
    }

    @Test func scopesClaudeSubagentsSeparatelyFromTheirRootAndSiblings() {
        var store = AgentSessionStore()
        store.upsert(event(provider: .claude, id: "root", status: .working))
        store.upsert(event(provider: .claude, id: "root", status: .working, scope: .subagent(agentID: "child-a")))
        store.upsert(event(provider: .claude, id: "root", status: .working, scope: .subagent(agentID: "child-b")))

        #expect(store.entries.count == 3)
        #expect(store.entries.map(\.key.scope) == [.subagent(agentID: "child-b"), .subagent(agentID: "child-a"), .primary])
    }

    @Test func subagentCompletionUsesTwoSecondGraceWhilePrimaryUsesFive() {
        let primary = AgentSessionKey(provider: .claude, sessionID: "root")
        let child = AgentSessionKey(provider: .claude, sessionID: "root", scope: .subagent(agentID: "child"))

        #expect(AgentSessionExpiryPolicy.gracePeriod(for: primary) == 5)
        #expect(AgentSessionExpiryPolicy.gracePeriod(for: child) == 2)
    }

    @Test func admitsCursorToolEventsOnlyForKnownPrimarySessions() {
        var store = AgentSessionStore()
        let orphanWorkerTool = event(provider: .cursor, id: "worker", status: .working, source: .tool)
        let rootPrompt = event(provider: .cursor, id: "root", status: .working, source: .prompt)
        let rootTool = event(provider: .cursor, id: "root", status: .reviewing, source: .tool)
        let childLifecycle = event(
            provider: .cursor,
            id: "root",
            status: .working,
            scope: .subagent(agentID: "child"),
            source: .subagentLifecycle
        )

        #expect(!store.accepts(orphanWorkerTool))
        #expect(store.accepts(rootPrompt))
        store.upsert(rootPrompt)
        #expect(store.accepts(rootTool))
        #expect(store.accepts(childLifecycle))
    }

    @Test func migratesOnlyOneLegacyProviderAndLeavesAmbiguousChoicesDisabled() {
        #expect(MonitorProviderMigration.fromLegacyProviders([.claude]) == .selected(.claude))
        #expect(MonitorProviderMigration.fromLegacyProviders([]) == .requiresReconfiguration)
        #expect(MonitorProviderMigration.fromLegacyProviders([.claude, .codex]) == .requiresReconfiguration)
        #expect(MonitorBubbleField.allCases == [.model, .job, .sessionName, .cost])
    }

    @Test func rejectsEventsFromAnUnselectedProvider() {
        let filter = MonitorEventFilter(selectedProvider: .claude)
        #expect(filter.accepts(event(provider: .claude, id: "selected", status: .working)))
        #expect(!filter.accepts(event(provider: .codex, id: "other", status: .working)))
    }

    private func event(
        provider: AgentProvider,
        id: String,
        status: AgentStatus,
        model: AgentSessionModel? = nil,
        activity: AgentActivity? = nil,
        scope: AgentSessionScope = .primary,
        source: AgentSessionEventSource = .unknown
    ) -> NormalizedAgentEvent {
        NormalizedAgentEvent(provider: provider, sessionID: id, status: status, model: model, activity: activity, scope: scope, source: source)
    }
}
