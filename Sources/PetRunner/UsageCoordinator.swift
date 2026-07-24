import Foundation
import PetRunnerCore

struct UsageSnapshot: Sendable {
    let today: UsageAggregate
    let month: UsageAggregate
    let all: UsageAggregate
    /// Optional title/project metadata from local transcript scans. Sessions
    /// themselves are built from `all.records`, not from this list.
    let sessionMetadata: [HistoricalUsageSession]
    let alerts: [BudgetEvaluation]
    let cursorStatus: String
    let cursorMessage: String?

    var todayText: String { UsageSnapshot.costText(today) }
    var monthText: String { UsageSnapshot.costText(month) }

    /// Back-compat alias for call sites still using the old name.
    var historicalSessions: [HistoricalUsageSession] { sessionMetadata }

    private static func costText(_ aggregate: UsageAggregate) -> String {
        aggregate.records.isEmpty ? "No data" : String(format: "$%.2f", aggregate.knownCostUSD)
    }
}

actor UsageCoordinator {
    private let store: UsageStore

    init(storeURL: URL) throws {
        store = try UsageStore(url: storeURL)
    }

    func refresh(
        configurations: [UsageProvider: ProviderBudgetConfiguration],
        enabledProviders: Set<UsageProvider> = Set(UsageProvider.allCases),
        now: Date = .now
    ) async throws -> UsageSnapshot {
        let codexRoot: URL
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            codexRoot = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
        } else {
            codexRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexEnabled = enabledProviders.contains(.codex)
        let claudeEnabled = enabledProviders.contains(.claude)
        let cursorEnabled = enabledProviders.contains(.cursor)
        let claudeRoots = claudeEnabled ? LocalUsageSource.resolvedClaudeRoots(homeDirectory: home) : []
        let codexFiles = codexEnabled ? LocalUsageSource.codexSourceFiles(root: codexRoot) : []
        let claudeFiles = claudeEnabled ? LocalUsageSource.claudeSourceFiles(roots: claudeRoots) : []
        let currentReceipts = LocalUsageSource.sourceReceipts(for: codexFiles + claudeFiles)
        let changedSources = Set(try store.changedSources(currentReceipts).map(\.sourceKey))
        let changedCodexFiles = codexFiles.filter { changedSources.contains(LocalUsageSource.sourceIdentity(for: $0)) }
        let changedClaudeFiles = claudeFiles.filter { changedSources.contains(LocalUsageSource.sourceIdentity(for: $0)) }
        // Parser-revision bumps invalidate every receipt. Rescanning with new
        // Claude source keys must replace the provider ledger; otherwise stale
        // uuid-keyed streaming chunks remain and costs stay inflated.
        let claudeFullRescan = claudeEnabled && !claudeFiles.isEmpty && changedClaudeFiles.count == claudeFiles.count
        let codexFullRescan = codexEnabled && !codexFiles.isEmpty && changedCodexFiles.count == codexFiles.count
        let codexScan = LocalUsageSource.codexScan(files: changedCodexFiles, now: now)
        let claudeScan = LocalUsageSource.claudeScan(files: changedClaudeFiles, now: now)
        if claudeFullRescan || codexFullRescan {
            if claudeFullRescan {
                try store.replaceRecords(provider: .claude, with: claudeScan.records)
                try store.replaceSessions(provider: .claude, with: claudeScan.sessions)
                try store.save(sourceReceipts: claudeScan.sourceReceipts)
            } else if !claudeScan.records.isEmpty || !claudeScan.sessions.isEmpty || !claudeScan.sourceReceipts.isEmpty {
                try store.upsert(claudeScan)
            }
            if codexFullRescan {
                try store.replaceRecords(provider: .codex, with: codexScan.records)
                try store.replaceSessions(provider: .codex, with: codexScan.sessions)
                try store.save(sourceReceipts: codexScan.sourceReceipts)
            } else if !codexScan.records.isEmpty || !codexScan.sessions.isEmpty || !codexScan.sourceReceipts.isEmpty {
                try store.upsert(codexScan)
            }
        } else if !codexScan.records.isEmpty || !claudeScan.records.isEmpty || !codexScan.sessions.isEmpty || !claudeScan.sessions.isEmpty || !codexScan.sourceReceipts.isEmpty || !claudeScan.sourceReceipts.isEmpty {
            try store.upsert(.init(
                records: codexScan.records + claudeScan.records,
                sessions: codexScan.sessions + claudeScan.sessions,
                sourceReceipts: codexScan.sourceReceipts + claudeScan.sourceReceipts))
        }
        var records: [AgentUsageRecord] = []
        let cursorStatus: String
        let cursorMessage: String?
        if !cursorEnabled {
            cursorStatus = "disabled"
            cursorMessage = "Cursor is disabled in Providers."
        } else if let credential = try? CursorAppAuthStore().cookieHeader() {
            do {
                records = try await CursorUsageClient().records(cookie: credential, now: now)
                cursorStatus = "connected"
                cursorMessage = nil
            } catch {
                cursorStatus = "error"
                cursorMessage = "Cursor usage could not be refreshed."
            }
        } else {
            cursorStatus = "notConnected"
            cursorMessage = "Sign in to Cursor.app to import usage automatically."
        }
        // Always replace the Cursor ledger on a successful fetch so progressive
        // token updates cannot accumulate under old unstable source keys.
        if cursorEnabled, cursorStatus == "connected" {
            try store.replaceRecords(provider: .cursor, with: records)
            let attribution = CursorLocalSessionIndex.load()
            try store.replaceSessions(
                provider: .cursor,
                with: CursorSessionGrouping.metadata(from: records, attribution: attribution)
            )
        }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? day
        let all = try store.aggregate()
        let metadataProviders = UsageProvider.allCases.filter(enabledProviders.contains)
        let sessionMetadata = metadataProviders.isEmpty
            ? []
            : try store.sessions(matching: .init(providers: Set(metadataProviders)))
        let today = try store.aggregate(.init(startDate: day))
        let thisMonth = try store.aggregate(.init(startDate: month))
        let enabledConfigurations = configurations.filter { enabledProviders.contains($0.key) }
        let alerts = BudgetPolicy.evaluations(
            records: all.records.filter { enabledProviders.contains($0.provider) },
            configurations: enabledConfigurations,
            calendar: calendar,
            now: now
        ).filter { evaluation in
            let key = BudgetPolicy.receiptKey(for: evaluation, calendar: calendar, now: now)
            if (try? store.hasReceipt(key)) == true { return false }
            try? store.saveReceipt(.init(key: key, createdAt: now))
            return true
        }
        return UsageSnapshot(
            today: today,
            month: thisMonth,
            all: all,
            sessionMetadata: sessionMetadata,
            alerts: alerts,
            cursorStatus: cursorStatus,
            cursorMessage: cursorMessage)
    }
}
