@testable import PetRunner
import Foundation
import PetRunnerCore
import Testing

@Suite("Dashboard API contracts")
@MainActor
struct DashboardAPIContractTests {
    @Test func coldLoadReturnsUsageUnavailableWhenSnapshotNil() throws {
        let api = makeAPI(usageState: { nil }, historyStore: { nil })
        let usage = api.response(for: get("/api/v2/usage"))
        #expect(usage.status == 409)
        let usageJSON = try jsonObject(usage)
        #expect(usageJSON["code"] as? String == "usage_unavailable")

        let sessions = api.response(for: get("/api/v2/sessions"))
        #expect(sessions.status == 409)
        #expect(try jsonObject(sessions)["code"] as? String == "usage_unavailable")

        let activity = api.response(for: get("/api/v2/activity"))
        #expect(activity.status == 409)
        #expect(try jsonObject(activity)["code"] as? String == "usage_unavailable")
    }

    @Test func overviewExposesAPIVersionAndCapabilityBooleans() throws {
        let api = makeAPI(usageState: { nil }, historyStore: { nil })
        let response = api.response(for: get("/api/v2/overview"))
        #expect(response.status == 200)
        let json = try jsonObject(response)
        #expect(json["apiVersion"] as? Int == 2)
        #expect(json["platform"] as? String == "macos")
        let capabilities = try #require(json["capabilities"] as? [String: Any])
        #expect(capabilities["usage"] as? Bool == true)
        #expect(capabilities["sessions"] as? Bool == false)
        #expect(capabilities["historicalSessions"] as? Bool == false)
        #expect(capabilities["liveSessions"] as? Bool == false)
        #expect(capabilities["agentMonitor"] as? Bool == true)
        #expect(capabilities["cursorConnection"] as? Bool == true)
    }

    @Test func overviewMarksSessionCapabilitiesWhenSnapshotPresent() throws {
        let api = makeAPI(usageState: { emptySnapshot() }, historyStore: { nil })
        let json = try jsonObject(api.response(for: get("/api/v2/overview")))
        let capabilities = try #require(json["capabilities"] as? [String: Any])
        #expect(capabilities["sessions"] as? Bool == true)
        #expect(capabilities["historicalSessions"] as? Bool == true)
        #expect(capabilities["liveSessions"] as? Bool == false)
    }

    @Test func refreshRoutesReturn202AndPromptKeychain() {
        var prompts: [Bool] = []
        let api = makeAPI(
            usageState: { nil },
            historyStore: { nil },
            onRefreshUsage: { prompts.append($0) }
        )

        let refresh = api.response(for: post("/api/v2/refresh"))
        #expect(refresh.status == 202)
        #expect(String(data: refresh.body, encoding: .utf8) == #"{"ok":true}"#)

        let usageRefresh = api.response(for: post("/api/v2/usage/refresh"))
        #expect(usageRefresh.status == 202)
        #expect(prompts == [true, true])
    }

    @Test func liveSessionsHistoryOutageDoesNotAffectUsageRoutes() throws {
        let api = makeAPI(
            usageState: { emptySnapshot() },
            historyStore: { nil },
            historyError: { "Session history is unavailable." }
        )

        let live = api.response(for: get("/api/v2/live-sessions"))
        #expect(live.status == 409)
        #expect(try jsonObject(live)["code"] as? String == "history_unavailable")

        let usage = api.response(for: get("/api/v2/usage"))
        #expect(usage.status == 200)
        let usageJSON = try jsonObject(usage)
        let totals = try #require(usageJSON["totals"] as? [String: Any])
        #expect(totals["tokens"] != nil)
        #expect(totals["cost"] != nil)
        #expect(totals["sessions"] != nil)
        #expect(totals["recordCount"] != nil)
    }

    @Test func providerScopedUsageUsesLargerPreviewLimit() throws {
        let now = Date()
        let records = (0..<2_001).map { index in
            AgentUsageRecord(
                id: "codex:\(index)",
                provider: .codex,
                sessionID: "session-\(index)",
                occurredAt: now,
                model: "gpt-5",
                tokens: .init(input: 1, output: 1),
                cost: .init(usd: 0.01, provenance: .calculated)
            )
        }
        let snapshot = UsageSnapshot(
            today: UsageAggregate(records: records),
            month: UsageAggregate(records: records),
            all: UsageAggregate(records: records),
            sessionMetadata: [],
            alerts: [],
            cursorStatus: "ready",
            cursorMessage: nil
        )
        let api = makeAPI(usageState: { snapshot }, historyStore: { nil })

        let unscoped = try jsonObject(api.response(for: get("/api/v2/usage")))
        #expect(unscoped["truncated"] as? Bool == true)
        #expect((unscoped["records"] as? [Any])?.count == 2_000)

        let scoped = try jsonObject(api.response(for: get("/api/v2/usage", query: ["provider": "codex"])))
        #expect(scoped["truncated"] as? Bool == false)
        #expect((scoped["records"] as? [Any])?.count == 2_001)
    }
}

@MainActor
private func makeAPI(
    usageState: @escaping () -> UsageSnapshot?,
    historyStore: @escaping () -> AgentSessionHistoryStore?,
    historyError: @escaping () -> String? = { nil },
    onRefreshUsage: @escaping (Bool) -> Void = { _ in }
) -> DashboardAPIController {
    DashboardAPIController(
        historyStore: historyStore,
        historyError: historyError,
        usageState: usageState,
        petState: {
            DashboardPetState(
                pets: [],
                failures: [],
                selectedPetID: nil,
                width: 128,
                autonomyEnabled: false,
                autonomyConfiguration: .default,
                petsDirectory: "/tmp/pets",
                petsDirectorySource: "test",
                petsDirectoryEditable: true
            )
        },
        showsStatusItem: { true },
        budgetConfigurations: { [:] },
        onSelectPet: { _ in },
        onSetWidth: { _ in },
        onResetPosition: {},
        onRemovePet: { _ in },
        onSetAutonomy: { _, _ in },
        onRefreshUsage: onRefreshUsage,
        onSetStatusItemVisible: { _ in },
        onImportPet: {},
        onChoosePetsDirectory: {},
        onSetPetsDirectory: { _ in },
        onRevealPetsDirectory: {},
        onSetBudgetConfigurations: { _ in }
    )
}

private func emptySnapshot() -> UsageSnapshot {
    UsageSnapshot(
        today: UsageAggregate(records: []),
        month: UsageAggregate(records: []),
        all: UsageAggregate(records: []),
        sessionMetadata: [],
        alerts: [],
        cursorStatus: "ready",
        cursorMessage: nil
    )
}

private func get(_ path: String, query: [String: String] = [:]) -> DashboardHTTPRequest {
    DashboardHTTPRequest(method: "GET", target: path, path: path, queryItems: query)
}

private func post(_ path: String) -> DashboardHTTPRequest {
    DashboardHTTPRequest(method: "POST", target: path, path: path)
}

private func jsonObject(_ response: DashboardHTTPResponse) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: response.body)
    return try #require(object as? [String: Any])
}
