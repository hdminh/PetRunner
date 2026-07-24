@testable import PetRunnerCore
import Foundation
import SQLite3
import Testing

struct UsageTests {
    @Test func storeDeduplicatesSourceKeysAndAggregatesSessions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(url: root.appendingPathComponent("usage.sqlite"))
        let record = AgentUsageRecord(id: "source:1", provider: .codex, sessionID: "session", occurredAt: .now, model: "gpt-5", tokens: .init(input: 100, cachedInput: 50, output: 25), cost: .init(usd: 0.1, provenance: .calculated))
        try store.upsert([record, record])
        let aggregate = try store.aggregate()
        #expect(aggregate.records.count == 1)
        #expect(aggregate.tokens.total == 175)
        #expect(aggregate.sessionCount == 1)
        #expect(aggregate.knownCostUSD == 0.1)
    }

    @Test func budgetsIgnoreEstimatedCursorRecords() {
        let now = Date()
        let records = [
            AgentUsageRecord(id: "cursor", provider: .cursor, sessionID: "estimated", occurredAt: now, model: nil, tokens: .init(input: 10_000), cost: .init(usd: nil, provenance: .estimated, isBudgetEligible: false)),
            AgentUsageRecord(id: "codex", provider: .codex, sessionID: "real", occurredAt: now, model: "gpt-5", tokens: .init(input: 1), cost: .init(usd: 4, provenance: .calculated)),
        ]
        let alerts = BudgetPolicy.evaluations(records: records, configurations: [.cursor: .init(dailyUSD: 1), .codex: .init(dailyUSD: 5)], now: now)
        #expect(alerts.map(\.provider) == [.codex])
        #expect(alerts.first?.threshold == .warning)
    }

    @Test func codexCumulativeTokenCountersBecomeDeltas() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions/2026/07/22", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-22T09:59:00Z","payload":{"conversation_id":"session-a","model_name":"gpt-5-codex"}}"#,
            #"{"payload":{"type":"token_count","conversation_id":"session-a","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}}}"#,
            #"{"payload":{"type":"token_count","conversation_id":"session-a","info":{"total_token_usage":{"input_tokens":14,"cached_input_tokens":4,"output_tokens":7}}}}"#,
        ].joined(separator: "\n")
        try Data(lines.utf8).write(to: file)
        let records = LocalUsageSource.codexRecords(root: root)
        #expect(records.count == 2)
        #expect(records.map(\.tokens.total) == [15, 10])
        #expect(records.map(\.model) == ["gpt-5-codex", "gpt-5-codex"])
    }

    @Test func claudeCacheCreationCountsAsInputWithoutDuplicatingCachedReads() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent("session-b.jsonl")
        let line = #"{"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":20,"cache_creation_input_tokens":8,"cache_read_input_tokens":5,"output_tokens":7}}}"#
        try Data(line.utf8).write(to: file)

        let records = LocalUsageSource.claudeRecords(roots: [projects])
        #expect(records.count == 1)
        #expect(records[0].tokens == UsageTokenBreakdown(input: 20, cachedInput: 5, cacheCreation: 8, output: 7))
        #expect(records[0].tokens.total == 40)
    }

    @Test func claudeStreamingChunksDedupByMessageAndRequestEarliestWins() throws {
        // Matches ccgauge earliest-wins: streaming snapshots share message.id +
        // requestId. Counting every uuid over-bills input.
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent("session-stream.jsonl")
        let lines = [
            #"{"type":"assistant","uuid":"u1","requestId":"req-1","sessionId":"sess","timestamp":"2026-07-22T10:00:00Z","message":{"id":"msg_abc","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"cache_read_input_tokens":200,"output_tokens":5}}}"#,
            #"{"type":"assistant","uuid":"u2","requestId":"req-1","sessionId":"sess","timestamp":"2026-07-22T10:00:01Z","message":{"id":"msg_abc","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"cache_read_input_tokens":200,"output_tokens":50}}}"#,
            #"{"type":"assistant","uuid":"u3","requestId":"req-1","sessionId":"sess","timestamp":"2026-07-22T10:00:02Z","message":{"id":"msg_abc","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"cache_read_input_tokens":200,"output_tokens":200}}}"#,
            #"{"type":"assistant","uuid":"u4","requestId":"req-2","sessionId":"sess","timestamp":"2026-07-22T10:01:00Z","message":{"id":"msg_def","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":4}}}"#,
        ].joined(separator: "\n")
        try Data(lines.utf8).write(to: file)

        let records = LocalUsageSource.claudeRecords(roots: [projects])
        #expect(records.count == 2)
        let streamed = records.first { $0.id.contains("msg_abc:req-1") }
        let second = records.first { $0.id.contains("msg_def:req-2") }
        // ccgauge earliest-wins keeps the first streaming snapshot (output=5).
        #expect(streamed?.tokens == UsageTokenBreakdown(input: 1000, cachedInput: 200, output: 5))
        #expect(second?.tokens == UsageTokenBreakdown(input: 10, output: 4))
        let expectedCost = BundledPricing.cost(
            model: "claude-sonnet-4-5",
            tokens: .init(input: 1000, cachedInput: 200, output: 5),
            occurredAt: streamed?.occurredAt
        )
        #expect(approximatelyEqual(streamed?.cost.usd, expectedCost.usd ?? -1))
        // Without dedup, three streaming chunks would bill input 3×.
        let inflated = BundledPricing.cost(
            model: "claude-sonnet-4-5",
            tokens: .init(input: 3000, cachedInput: 600, output: 255)
        ).usd ?? 0
        #expect((streamed?.cost.usd ?? 0) < inflated * 0.5)
    }

    @Test func claudeDedupFallsBackToMessageIdWhenRequestIdMissing() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent("session-mid.jsonl")
        let lines = [
            #"{"type":"assistant","uuid":"a","sessionId":"sess","timestamp":"2026-07-22T10:00:00Z","message":{"id":"msg_only","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":1}}}"#,
            #"{"type":"assistant","uuid":"b","sessionId":"sess","timestamp":"2026-07-22T10:00:01Z","message":{"id":"msg_only","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":40}}}"#,
        ].joined(separator: "\n")
        try Data(lines.utf8).write(to: file)

        let records = LocalUsageSource.claudeRecords(roots: [projects])
        #expect(records.count == 1)
        #expect(records[0].tokens.output == 1) // earliest-wins
        #expect(records[0].id.contains("mid:msg_only"))
    }

    @Test func codexSourceFilesPreferLiveBasenameOverArchivedCopy() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let liveDir = root.appendingPathComponent("sessions/2026/07/22", isDirectory: true)
        let archivedDir = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)
        let name = "rollout-dup.jsonl"
        let tokenLine = #"{"timestamp":"2026-07-22T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2}}}}"#
        let meta = #"{"timestamp":"2026-07-22T09:59:00Z","type":"session_meta","payload":{"id":"same-session","model":"gpt-5-codex"}}"#
        let contents = [meta, tokenLine].joined(separator: "\n")
        try Data(contents.utf8).write(to: liveDir.appendingPathComponent(name))
        try Data(contents.utf8).write(to: archivedDir.appendingPathComponent(name))

        let files = LocalUsageSource.codexSourceFiles(root: root)
        #expect(files.count == 1)
        #expect(files[0].path.contains("/sessions/"))
        let records = LocalUsageSource.codexRecords(root: root)
        #expect(records.count == 1)
        #expect(records[0].tokens.total == 12)
    }

    @Test func pricingCatalogListsClaudeAndCodexRatesPerMillion() {
        let all = BundledPricing.catalog()
        #expect(all.contains { $0.id == "claude-sonnet-4-5" && $0.provider == .claude })
        #expect(all.contains { $0.id == "gpt-5-codex" && $0.provider == .codex })
        #expect(!all.contains { $0.provider == .cursor })

        let sonnet = all.first { $0.id == "claude-sonnet-4-5" }
        #expect(sonnet?.inputPerMillionUSD == 3)
        #expect(sonnet?.outputPerMillionUSD == 15)
        #expect(sonnet?.cacheReadPerMillionUSD == 0.3)
        #expect(sonnet?.cacheWritePerMillionUSD == 3.75)
        #expect(sonnet?.contextThreshold == 200_000)

        let claudeOnly = BundledPricing.catalog(provider: .claude)
        #expect(claudeOnly.allSatisfy { $0.provider == .claude })
        #expect(claudeOnly.count == BundledPricing.catalog().filter { $0.provider == .claude }.count)

        let cursorOnly = BundledPricing.catalog(provider: .cursor)
        #expect(cursorOnly.isEmpty)
    }

    @Test func pricingSeparatesClaudeCacheCreationAndNormalizesAliases() {
        let tokens = UsageTokenBreakdown(input: 100, cachedInput: 20, cacheCreation: 10, output: 5)
        let direct = BundledPricing.cost(model: "claude-sonnet-4-5", tokens: tokens)
        let vertexAlias = BundledPricing.cost(model: "anthropic.claude-sonnet-4-5-v1:0", tokens: tokens)

        #expect(approximatelyEqual(direct.usd, 0.0004185))
        #expect(vertexAlias == direct)
        #expect(direct.pricingVersion == BundledPricing.version)
        #expect(BundledPricing.version.contains("ccgauge"))
    }

    @Test func codexPricingDoesNotDoubleBillCachedInputAndRecognizesDatedAlias() {
        let tokens = UsageTokenBreakdown(input: 100, cachedInput: 40, output: 5)
        let direct = BundledPricing.cost(model: "gpt-5-codex", tokens: tokens)
        let dated = BundledPricing.cost(model: "openai/gpt-5-codex-2026-07-01", tokens: tokens)

        #expect(approximatelyEqual(direct.usd, 0.00013))
        #expect(dated == direct)
    }

    @Test func codexReasoningIsDisplayedButNotBilledTwice() {
        let base = UsageTokenBreakdown(input: 100, output: 20)
        let withReasoning = UsageTokenBreakdown(input: 100, output: 20, reasoning: 20)

        #expect(BundledPricing.cost(model: "gpt-5", tokens: withReasoning).usd == BundledPricing.cost(model: "gpt-5", tokens: base).usd)
        #expect(withReasoning.total == base.total)
    }

    @Test func displayedTokenTotalsFollowProviderSemantics() {
        let tokens = UsageTokenBreakdown(input: 100, cachedInput: 50, output: 25)
        let codex = AgentUsageRecord(id: "codex", provider: .codex, sessionID: "c", occurredAt: .now, model: nil, tokens: tokens, cost: .init(usd: nil, provenance: .unavailable))
        let claude = AgentUsageRecord(id: "claude", provider: .claude, sessionID: "a", occurredAt: .now, model: nil, tokens: tokens, cost: .init(usd: nil, provenance: .unavailable))

        #expect(codex.totalTokens == 125)
        #expect(claude.totalTokens == 175)
        #expect(UsageAggregate(records: [codex, claude]).totalTokens == 300)
    }

    @Test func claudeOneHourCacheCreationMatchesCcgaugeCostFromUsage() {
        // 100 input * 3e-6 + 10 * (2*3e-6) 1h write = 0.0003 + 0.00006 = 0.00036
        let oneHourCache = UsageTokenBreakdown(input: 100, cacheCreation: 10, cacheCreation1h: 10)
        #expect(approximatelyEqual(BundledPricing.cost(model: "claude-sonnet-4-5", tokens: oneHourCache).usd, 0.00036))

        // ccgauge drops 200k+ tiers — long prompts still bill at standard rates.
        let longContext = UsageTokenBreakdown(input: 200_001)
        #expect(approximatelyEqual(BundledPricing.cost(model: "claude-sonnet-4-5", tokens: longContext).usd, 0.600003))
    }

    @Test func ccgaugeStyleCostIgnoresLongContextSurchargeAndFallsBackByFamily() {
        let tokens = UsageTokenBreakdown(input: 200_001)
        let beforeChange = Date(timeIntervalSince1970: 1_700_000_000)
        let afterChange = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(approximatelyEqual(BundledPricing.cost(model: "claude-sonnet-4-6", tokens: tokens, occurredAt: beforeChange).usd, 0.600003))
        #expect(approximatelyEqual(BundledPricing.cost(model: "claude-sonnet-4-6", tokens: tokens, occurredAt: afterChange).usd, 0.600003))
        // Unknown sonnet-shaped id → family fallback (claude-sonnet-4-6 rates).
        #expect(approximatelyEqual(BundledPricing.cost(model: "claude-sonnet-9-9-experimental", tokens: .init(input: 1_000_000)).usd, 3.0))
        #expect(BundledPricing.cost(model: "totally-unknown-widget", tokens: tokens).usd == nil)
    }

    @Test func storeRoundTripsCacheCreationCategories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(url: root.appendingPathComponent("usage.sqlite"))
        let tokens = UsageTokenBreakdown(input: 1, cachedInput: 2, cacheCreation: 3, cacheCreation1h: 1, output: 4)
        try store.upsert([.init(id: "cache", provider: .claude, sessionID: "session", occurredAt: .now, model: "claude-sonnet-4-5", tokens: tokens, cost: .init(usd: 0.1, provenance: .calculated))])

        #expect(try store.records().first?.tokens == tokens)
    }

    @Test func usageSessionAggregatorGroupsByProviderAndSessionAndSumsCost() {
        let day = Date(timeIntervalSince1970: 1_753_228_800) // 2025-07-23T00:00:00Z approx window
        let earlier = day.addingTimeInterval(3_600)
        let later = day.addingTimeInterval(7_200)
        let records = [
            AgentUsageRecord(id: "a1", provider: .claude, sessionID: "sess-a", occurredAt: later, model: "claude-sonnet", tokens: .init(input: 10, output: 5), cost: .init(usd: 0.2, provenance: .calculated)),
            AgentUsageRecord(id: "a2", provider: .claude, sessionID: "sess-a", occurredAt: earlier, model: "claude-opus", tokens: .init(input: 20, output: 10), cost: .init(usd: 0.5, provenance: .calculated)),
            AgentUsageRecord(id: "b1", provider: .codex, sessionID: "sess-b", occurredAt: earlier, model: "gpt-5", tokens: .init(input: 4, output: 1), cost: .init(usd: 0.05, provenance: .calculated)),
            AgentUsageRecord(id: "c1", provider: .cursor, sessionID: "conv:chat-1", occurredAt: later, model: "composer", tokens: .init(input: 8, output: 2), cost: .init(usd: 0.11, provenance: .providerReported)),
        ]
        let metadata = [
            HistoricalUsageSession(provider: .claude, sessionID: "sess-a", projectName: "PetRunner", title: "Fix sessions", startedAt: earlier, lastActivityAt: later, model: "claude-sonnet", projectPath: "/Users/me/Documents/PetRunner"),
            HistoricalUsageSession(provider: .cursor, sessionID: "conv:chat-1", projectName: "PetRunner", title: "Fix cursor projects", startedAt: later, lastActivityAt: later, model: "composer", projectPath: "/Users/me/Documents/PetRunner"),
        ]
        let sessions = UsageSessionAggregator.sessions(from: records, metadata: metadata)
        #expect(Set(sessions.map(\.sessionID)) == Set(["sess-a", "sess-b", "conv:chat-1"]))
        #expect(sessions.first?.lastActivityAt == later)
        let claude = sessions.first { $0.sessionID == "sess-a" }
        #expect(claude?.provider == .claude)
        #expect(claude?.title == "Fix sessions")
        #expect(claude?.project == "PetRunner")
        #expect(claude?.projectPath == "/Users/me/Documents/PetRunner")
        #expect(claude?.requestCount == 2)
        #expect(claude?.knownCostUSD == 0.7)
        #expect(claude?.models == ["claude-opus", "claude-sonnet"])
        #expect(claude?.startedAt == earlier)
        #expect(claude?.lastActivityAt == later)
        let cursor = sessions.first { $0.provider == .cursor }
        #expect(cursor?.knownCostUSD == 0.11)
        #expect(cursor?.title == "Fix cursor projects")
        #expect(cursor?.project == "PetRunner")
        #expect(cursor?.projectPath == "/Users/me/Documents/PetRunner")
        #expect(sessions.filter { $0.provider == .codex }.count == 1)

        let projects = UsageSessionAggregator.projects(from: records, metadata: metadata)
        let petRunner = projects.filter { $0.name == "PetRunner" }
        #expect(petRunner.count == 2) // Claude + Cursor share the folder name but are separate provider cards
        #expect(petRunner.map(\.provider).sorted { $0.rawValue < $1.rawValue } == [.claude, .cursor])
        #expect(petRunner.first { $0.provider == .claude }?.path == "/Users/me/Documents/PetRunner")
        #expect(petRunner.first { $0.provider == .claude }?.sessionCount == 1)
        #expect(petRunner.first { $0.provider == .claude }?.requestCount == 2)
        #expect(petRunner.first { $0.provider == .claude }?.knownCostUSD == 0.7)
        #expect(petRunner.first { $0.provider == .cursor }?.knownCostUSD == 0.11)

        let models = UsageSessionAggregator.models(from: records)
        #expect(models.contains { $0.model == "claude-opus" && $0.requestCount == 1 })
        #expect(models.first?.knownCostUSD ?? 0 >= models.last?.knownCostUSD ?? 0)
    }

    @Test func cursorSessionGroupingPrefersConversationIdAndClustersByGap() {
        let t0 = Date(timeIntervalSince1970: 1_753_228_800)
        let records = [
            AgentUsageRecord(id: "c1", provider: .cursor, sessionID: "pending", occurredAt: t0, model: "composer", tokens: .init(input: 1, output: 1), cost: .init(usd: 0.1, provenance: .providerReported)),
            AgentUsageRecord(id: "c2", provider: .cursor, sessionID: "pending", occurredAt: t0.addingTimeInterval(600), model: "composer", tokens: .init(input: 1, output: 1), cost: .init(usd: 0.2, provenance: .providerReported)),
            AgentUsageRecord(id: "c3", provider: .cursor, sessionID: "pending", occurredAt: t0.addingTimeInterval(4_000), model: "gpt-5", tokens: .init(input: 1, output: 1), cost: .init(usd: 0.3, provenance: .providerReported)),
            AgentUsageRecord(id: "c4", provider: .cursor, sessionID: "pending", occurredAt: t0.addingTimeInterval(4_100), model: "gpt-5", tokens: .init(input: 1, output: 1), cost: .init(usd: 0.4, provenance: .providerReported)),
        ]
        let grouped = CursorSessionGrouping.assignSessionIDs(
            records,
            conversationIDs: ["c1": "abc", "c2": "abc"]
        )
        let byID = Dictionary(uniqueKeysWithValues: grouped.map { ($0.id, $0.sessionID) })
        #expect(byID["c1"] == "conv:abc")
        #expect(byID["c2"] == "conv:abc")
        #expect(byID["c3"] == byID["c4"])
        #expect(byID["c3"]?.hasPrefix("gap:") == true)
        #expect(byID["c3"] != byID["c1"])

        let sessions = UsageSessionAggregator.sessions(from: grouped, metadata: CursorSessionGrouping.metadata(from: grouped))
        #expect(sessions.count == 2)
        let conversation = sessions.first { $0.sessionID == "conv:abc" }
        #expect(conversation?.requestCount == 2)
        #expect(approximatelyEqual(conversation?.knownCostUSD, 0.3))
        #expect(conversation?.project == nil)
        #expect(conversation?.durationSeconds == 600)

        let projects = UsageSessionAggregator.projects(from: grouped, metadata: CursorSessionGrouping.metadata(from: grouped))
        #expect(projects.count == 1)
        #expect(projects.first?.name == "(unknown)")
        #expect(approximatelyEqual(projects.first?.knownCostUSD, 1.0))
    }

    @Test func cursorMetadataUsesLocalAttributionForDistinctProjects() {
        let t0 = Date(timeIntervalSince1970: 1_753_228_800)
        let records = [
            AgentUsageRecord(id: "c1", provider: .cursor, sessionID: "conv:aaa", occurredAt: t0, model: "composer", tokens: .init(input: 1, output: 1), cost: .init(usd: 1.0, provenance: .providerReported)),
            AgentUsageRecord(id: "c2", provider: .cursor, sessionID: "conv:bbb", occurredAt: t0.addingTimeInterval(60), model: "composer", tokens: .init(input: 1, output: 1), cost: .init(usd: 2.0, provenance: .providerReported)),
            AgentUsageRecord(id: "c3", provider: .cursor, sessionID: "conv:ccc", occurredAt: t0.addingTimeInterval(120), model: "composer", tokens: .init(input: 1, output: 1), cost: .init(usd: 0.5, provenance: .providerReported)),
        ]
        let attribution: [String: CursorSessionAttribution] = [
            "aaa": .init(projectPath: "/Users/me/Documents/PetRunner", title: "Fix projects"),
            "bbb": .init(projectPath: "/Users/me/Documents/petrunner-web", projectName: "Web landing page project", title: "Landing"),
        ]
        let metadata = CursorSessionGrouping.metadata(from: records, attribution: attribution)
        let projects = UsageSessionAggregator.projects(from: records, metadata: metadata)
        #expect(Set(projects.map(\.name)) == Set(["PetRunner", "Web landing page project", "(unknown)"]))
        #expect(projects.first { $0.name == "PetRunner" }?.path == "/Users/me/Documents/PetRunner")
        #expect(projects.first { $0.name == "PetRunner" }?.sessionCount == 1)
        #expect(approximatelyEqual(projects.first { $0.name == "PetRunner" }?.knownCostUSD, 1.0))
        #expect(approximatelyEqual(projects.first { $0.name == "Web landing page project" }?.knownCostUSD, 2.0))
        #expect(approximatelyEqual(projects.first { $0.name == "(unknown)" }?.knownCostUSD, 0.5))
        #expect(approximatelyEqual(projects.map(\.knownCostUSD).reduce(0, +), 3.5))
        let petSession = UsageSessionAggregator.sessions(from: records, metadata: metadata)
            .first { $0.sessionID == "conv:aaa" }
        #expect(petSession?.title == "Fix projects")
        #expect(petSession?.project == "PetRunner")
    }

    @Test func cursorLocalSessionIndexReadsMembershipAndComposerHeaders() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDB = root.appendingPathComponent("state.vscdb")
        try Self.createCursorStateFixture(at: stateDB)
        let workspaceStorage = root.appendingPathComponent("workspaceStorage", isDirectory: true)
        let ws = workspaceStorage.appendingPathComponent("ws-pet", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try Data(#"{"folder":"file:///Users/me/Documents/PetRunner"}"#.utf8)
            .write(to: ws.appendingPathComponent("workspace.json"))

        let projectsDir = root.appendingPathComponent("projects", isDirectory: true)
        let transcriptProject = projectsDir.appendingPathComponent("Users-me-Documents-petrunner-web", isDirectory: true)
        let transcriptConv = transcriptProject.appendingPathComponent("agent-transcripts/ddd-from-transcript", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptConv, withIntermediateDirectories: true)

        let searchDB = root.appendingPathComponent("conversation-search.db")
        try Self.createConversationSearchFixture(at: searchDB)

        let attribution = CursorLocalSessionIndex.load(
            paths: .init(
                stateDatabase: stateDB,
                conversationSearchDatabase: searchDB,
                workspaceStorageDirectory: workspaceStorage,
                cursorProjectsDirectory: projectsDir
            )
        )
        #expect(attribution["aaa-membership"]?.projectPath == "/Users/me/Documents/PetRunner")
        #expect(attribution["aaa-membership"]?.projectName == "PetRunner")
        #expect(attribution["aaa-membership"]?.title == "Membership chat")
        #expect(attribution["bbb-composer"]?.projectPath == "/Users/me/Documents/world-cup-bets")
        #expect(attribution["bbb-composer"]?.title == "Composer titled")
        #expect(attribution["ddd-from-transcript"]?.projectPath == "/Users/me/Documents/petrunner-web")
    }

    @Test func cursorLocalSessionIndexToleratesCollidingWorkspaceFolderNames() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStorage = root.appendingPathComponent("workspaceStorage", isDirectory: true)
        for (id, uri) in [
            ("ws-flat", "file:///Users/me/Documents/road-map"),
            ("ws-nested", "file:///Users/me/Documents/road/map"),
        ] {
            let folder = workspaceStorage.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"folder":"\#(uri)"}"#.utf8)
                .write(to: folder.appendingPathComponent("workspace.json"))
        }

        let projectsDir = root.appendingPathComponent("projects", isDirectory: true)
        let transcripts = projectsDir
            .appendingPathComponent("Users-me-Documents-road-map/agent-transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        try Data().write(to: transcripts.appendingPathComponent("eee-colliding"))

        let attribution = CursorLocalSessionIndex.load(
            paths: .init(
                stateDatabase: root.appendingPathComponent("missing.vscdb"),
                workspaceStorageDirectory: workspaceStorage,
                cursorProjectsDirectory: projectsDir
            )
        )
        #expect(attribution["eee-colliding"]?.projectPath != nil)
    }

    @Test func usageStoreReplaceSessionsOverwritesCursorPlaceholders() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(url: root.appendingPathComponent("usage.sqlite"))
        let now = Date()
        try store.upsert(sessions: [
            HistoricalUsageSession(provider: .cursor, sessionID: "conv:x", projectName: "Cursor", title: "old", startedAt: now, lastActivityAt: now, model: "composer", projectPath: nil),
            HistoricalUsageSession(provider: .codex, sessionID: "keep", projectName: "CodexProj", title: "codex", startedAt: now, lastActivityAt: now, model: "gpt-5", projectPath: "/tmp/codex"),
        ])
        try store.replaceSessions(provider: .cursor, with: [
            HistoricalUsageSession(provider: .cursor, sessionID: "conv:x", projectName: "PetRunner", title: "new", startedAt: now, lastActivityAt: now, model: "composer", projectPath: "/Users/me/Documents/PetRunner"),
        ])
        let sessions = try store.sessions()
        let cursor = sessions.first { $0.provider == .cursor }
        let codex = sessions.first { $0.provider == .codex }
        #expect(cursor?.projectName == "PetRunner")
        #expect(cursor?.projectPath == "/Users/me/Documents/PetRunner")
        #expect(cursor?.title == "new")
        #expect(codex?.projectName == "CodexProj")
    }

    @Test func usageSessionAggregatorIgnoresMetadataOnlySessionsWithoutRecords() {
        let records = [
            AgentUsageRecord(id: "only", provider: .codex, sessionID: "live", occurredAt: .now, model: "gpt-5", tokens: .init(input: 1), cost: .init(usd: 0.01, provenance: .calculated)),
        ]
        let metadata = [
            HistoricalUsageSession(provider: .claude, sessionID: "orphan", projectName: "X", title: "Ghost", startedAt: .now, lastActivityAt: .now, model: nil),
        ]
        let sessions = UsageSessionAggregator.sessions(from: records, metadata: metadata)
        #expect(sessions.map(\.sessionID) == ["live"])
    }

    @Test func usageActivityAggregatorBuildsHeatmapAndStreaks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func day(_ y: Int, _ m: Int, _ d: Int, hour: Int) -> Date {
            var components = DateComponents()
            components.year = y; components.month = m; components.day = d; components.hour = hour
            return calendar.date(from: components)!
        }
        let records = [
            AgentUsageRecord(id: "1", provider: .claude, sessionID: "a", occurredAt: day(2026, 7, 20, hour: 23), model: "sonnet", tokens: .init(input: 10, output: 5), cost: .init(usd: 0.1, provenance: .calculated)), // Mon 11pm
            AgentUsageRecord(id: "2", provider: .codex, sessionID: "b", occurredAt: day(2026, 7, 21, hour: 23), model: "gpt", tokens: .init(input: 20, output: 10), cost: .init(usd: 0.2, provenance: .calculated)), // Tue 11pm
            AgentUsageRecord(id: "3", provider: .cursor, sessionID: "c", occurredAt: day(2026, 7, 22, hour: 23), model: "composer", tokens: .init(input: 30, output: 15), cost: .init(usd: 0.3, provenance: .providerReported)), // Wed 11pm
            AgentUsageRecord(id: "4", provider: .claude, sessionID: "d", occurredAt: day(2026, 7, 22, hour: 11), model: "opus", tokens: .init(input: 4, output: 1), cost: .init(usd: 0.05, provenance: .calculated)), // Wed 11am
            AgentUsageRecord(id: "5", provider: .claude, sessionID: "e", occurredAt: day(2026, 7, 24, hour: 23), model: "sonnet", tokens: .init(input: 8, output: 2), cost: .init(usd: 0.08, provenance: .calculated)), // Fri 11pm — gap after Wed
        ]
        let now = day(2026, 7, 24, hour: 12)
        let stats = UsageActivityAggregator.stats(from: records, calendar: calendar, now: now)
        #expect(stats.activeDays == 4)
        #expect(stats.requestCount == 5)
        #expect(stats.peakHour == 23)
        #expect(stats.heatmap[1][23] == 1) // Monday
        #expect(stats.heatmap[2][23] == 1) // Tuesday
        #expect(stats.heatmap[3][23] == 1) // Wednesday night
        #expect(stats.heatmap[3][11] == 1) // Wednesday morning
        #expect(stats.heatmap[5][23] == 1) // Friday
        #expect(stats.heatmapMax == 1)
        #expect(stats.tokenHeatmap[3][23] == 45)
        #expect(stats.longestStreak == 3) // Mon–Wed
        #expect(stats.currentStreak == 1) // Friday only (gap Thursday)
        #expect(stats.comparison != nil)
    }

    @Test func usageActivityStreakResetsWhenLastDayOlderThanYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            var components = DateComponents()
            components.year = y; components.month = m; components.day = d
            return calendar.date(from: components)!
        }
        let streaks = UsageActivityAggregator.computeStreaks(
            dayKeys: ["2026-07-01", "2026-07-02", "2026-07-03"],
            windowDays: 365,
            calendar: calendar,
            now: day(2026, 7, 10)
        )
        #expect(streaks.longest == 3)
        #expect(streaks.current == 0)
    }

    @Test func pickTokenComparisonChoosesLargestReferenceAtLeastFiveX() {
        let comparison = UsageActivityAggregator.pickTokenComparison(totalTokens: 57_200_000 * 9)
        #expect(comparison?.refKey == "encyclopediaBritannica")
        #expect(comparison.map { abs($0.multiplier - 9) < 0.01 } == true)
        #expect(UsageActivityAggregator.pickTokenComparison(totalTokens: 0) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("petrunner-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func approximatelyEqual(_ actual: Double?, _ expected: Double, tolerance: Double = 1e-12) -> Bool {
        actual.map { abs($0 - expected) < tolerance } ?? false
    }

    private static func createCursorStateFixture(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw UsageStoreError.open
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);", nil, nil, nil) == SQLITE_OK else {
            throw UsageStoreError.statement
        }
        let projects = """
        [{"id":"proj-pet","name":"New Project","workspace":{"id":"ws-pet","uri":{"fsPath":"/Users/me/Documents/PetRunner","path":"/Users/me/Documents/PetRunner","scheme":"file"}}}]
        """
        let membership = #"{"aaa-membership":"proj-pet"}"#
        let headers = """
        {"allComposers":[{"composerId":"bbb-composer","name":"Composer titled","workspaceIdentifier":{"id":"ws-bets","uri":{"fsPath":"/Users/me/Documents/world-cup-bets","path":"/Users/me/Documents/world-cup-bets","scheme":"file"}}}]}
        """
        let workspaceMeta = """
        {"entries":[{"workspaceId":"ws-pet","folderUri":"file:///Users/me/Documents/PetRunner"},{"workspaceId":"ws-web","folderUri":"file:///Users/me/Documents/petrunner-web"},{"workspaceId":"ws-bets","folderUri":"file:///Users/me/Documents/world-cup-bets"}]}
        """
        try insertItem(database, key: "glass.localAgentProjects.v1", value: projects)
        try insertItem(database, key: "glass.localAgentProjectMembership.v1", value: membership)
        try insertItem(database, key: "composer.composerHeaders", value: headers)
        try insertItem(database, key: "workspaceMetadata.entries", value: workspaceMeta)
    }

    private static func createConversationSearchFixture(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw UsageStoreError.open
        }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE conversations (
            fts_rowid INTEGER PRIMARY KEY,
            source TEXT NOT NULL,
            scope TEXT NOT NULL,
            id TEXT NOT NULL,
            title TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            is_archived INTEGER NOT NULL,
            root_fingerprint TEXT,
            cache_fingerprint TEXT
        );
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw UsageStoreError.statement
        }
        let sql = "INSERT INTO conversations (source,scope,id,title,updated_at,is_archived,root_fingerprint) VALUES ('local','','aaa-membership','Membership chat',1,0,'fp');"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageStoreError.statement
        }
    }

    private static func insertItem(_ database: OpaquePointer?, key: String, value: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO ItemTable (key, value) VALUES (?, ?);", -1, &statement, nil) == SQLITE_OK else {
            throw UsageStoreError.statement
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageStoreError.statement }
    }
}
