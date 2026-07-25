import Foundation

/// Live overlay on top of `BundledPricing`. Refresh pulls Anthropic/OpenAI
/// rates from models.dev (primary) and enriches cache-write costs from LiteLLM
/// when models.dev omits them. Persists under Application Support so relaunches
/// keep the latest catalog; bundled rates remain the offline fallback.
public final class PricingCatalogStore: @unchecked Sendable {
    public static let shared = PricingCatalogStore()

    public static let modelsDevURL = URL(string: "https://models.dev/api.json")!
    public static let litellmURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    public struct OverlayRates: Codable, Equatable, Sendable {
        public var inputPerMillion: Double
        public var outputPerMillion: Double
        public var cacheReadPerMillion: Double?
        public var cacheWritePerMillion: Double?

        public init(
            inputPerMillion: Double,
            outputPerMillion: Double,
            cacheReadPerMillion: Double? = nil,
            cacheWritePerMillion: Double? = nil
        ) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
            self.cacheReadPerMillion = cacheReadPerMillion
            self.cacheWritePerMillion = cacheWritePerMillion
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var version: String
        public var source: String
        public var refreshedAt: Date
        public var claude: [String: OverlayRates]
        public var codex: [String: OverlayRates]
    }

    public struct RefreshResult: Equatable, Sendable {
        public let version: String
        public let source: String
        public let claudeCount: Int
        public let codexCount: Int
        public let changed: Bool
    }

    public enum RefreshError: Error, Equatable, LocalizedError {
        case invalidResponse
        case emptyCatalog
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Pricing providers returned an invalid catalog."
            case .emptyCatalog: return "Pricing refresh returned no Claude/Codex models."
            case .transport(let message): return message
            }
        }
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?
    private let fileURL: URL
    private let modelsDevEndpoint: URL
    private let litellmEndpoint: URL

    public init(
        fileURL: URL? = nil,
        modelsDevURL: URL = PricingCatalogStore.modelsDevURL,
        litellmURL: URL = PricingCatalogStore.litellmURL
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("PetRunner", isDirectory: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("pricing-overlay.json", isDirectory: false)
        self.modelsDevEndpoint = modelsDevURL
        self.litellmEndpoint = litellmURL
        loadFromDisk()
    }

    /// Bundled baseline version when no overlay is loaded.
    public var bundledVersion: String { BundledPricing.bundledVersion }

    public var effectiveVersion: String {
        lock.lock(); defer { lock.unlock() }
        return snapshot?.version ?? BundledPricing.bundledVersion
    }

    public var sourceLabel: String {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot else { return "bundled" }
        return snapshot.source
    }

    public var catalogLabel: String {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot else {
            return "Bundled catalog · version \(BundledPricing.bundledVersion)"
        }
        let stamp = ISO8601DateFormatter().string(from: snapshot.refreshedAt)
        return "\(snapshot.source) · \(snapshot.version) · refreshed \(stamp)"
    }

    public var hasOverlay: Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot != nil
    }

    public func claudeOverlay(for model: String) -> OverlayRates? {
        lock.lock(); defer { lock.unlock() }
        return snapshot?.claude[model]
    }

    public func codexOverlay(for model: String) -> OverlayRates? {
        lock.lock(); defer { lock.unlock() }
        return snapshot?.codex[model]
    }

    public func overlayClaudeModels() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return snapshot.map { Array($0.claude.keys) } ?? []
    }

    public func overlayCodexModels() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return snapshot.map { Array($0.codex.keys) } ?? []
    }

    public func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        snapshot = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Blocking refresh for the dashboard HTTP handler.
    /// Network I/O runs on a detached task so waiting on the MainActor HTTP
    /// server cannot deadlock URLSession completion callbacks.
    public func refreshSync(timeout: TimeInterval = 20) throws -> RefreshResult {
        let modelsURL = modelsDevEndpoint
        let litellmURL = litellmEndpoint
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var fetchOutcome: Result<(Data, Data?), Error>?
        Task.detached {
            do {
                let session = URLSession(configuration: .ephemeral)
                let modelsData = try await Self.fetchData(from: modelsURL, session: session)
                let litellmData = try? await Self.fetchData(from: litellmURL, session: session)
                fetchOutcome = .success((modelsData, litellmData))
            } catch {
                fetchOutcome = .failure(error)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        switch fetchOutcome {
        case .success(let (modelsData, litellmData)):
            return try applyRemotePayloads(modelsDev: modelsData, litellm: litellmData)
        case .failure(let error):
            throw error
        case nil:
            throw RefreshError.transport("Pricing refresh timed out.")
        }
    }

    public func refresh(session: URLSession = .shared) async throws -> RefreshResult {
        let modelsData: Data
        do {
            modelsData = try await Self.fetchData(from: modelsDevEndpoint, session: session)
        } catch let error as RefreshError {
            throw error
        } catch {
            throw RefreshError.transport(error.localizedDescription)
        }

        let litellmData = try? await Self.fetchData(from: litellmEndpoint, session: session)
        return try applyRemotePayloads(modelsDev: modelsData, litellm: litellmData)
    }

    private static func fetchData(from url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("PetRunner", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RefreshError.invalidResponse
        }
        return data
    }

    /// Test / scripting entry that applies already-fetched payloads.
    @discardableResult
    public func applyRemotePayloads(modelsDev: Data, litellm: Data? = nil) throws -> RefreshResult {
        let parsed = try Self.parseModelsDev(modelsDev)
        var claude = parsed.claude
        var codex = parsed.codex
        if let litellm, let enrichment = try? Self.parseLiteLLM(litellm) {
            mergeMissingCacheWrite(into: &claude, from: enrichment.claude)
            mergeMissingCacheWrite(into: &codex, from: enrichment.codex)
            // Prefer LiteLLM when it knows a model models.dev does not list yet.
            for (id, rates) in enrichment.claude where claude[id] == nil {
                claude[id] = rates
            }
            for (id, rates) in enrichment.codex where codex[id] == nil {
                codex[id] = rates
            }
        }
        guard !claude.isEmpty || !codex.isEmpty else { throw RefreshError.emptyCatalog }

        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let next = Snapshot(
            version: "\(BundledPricing.bundledVersion)+\(day)-remote",
            source: litellm == nil ? "models.dev" : "models.dev+litellm",
            refreshedAt: Date(),
            claude: claude,
            codex: codex
        )
        let previous: Snapshot?
        lock.lock()
        previous = snapshot
        snapshot = next
        lock.unlock()
        try persist(next)
        let changed = previous?.claude != next.claude || previous?.codex != next.codex || previous == nil
        return RefreshResult(
            version: next.version,
            source: next.source,
            claudeCount: claude.count,
            codexCount: codex.count,
            changed: changed
        )
    }

    // MARK: - Parsing

    private struct ProviderBuckets {
        var claude: [String: OverlayRates]
        var codex: [String: OverlayRates]
    }

    static func parseModelsDev(_ data: Data) throws -> ProviderBuckets {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.invalidResponse
        }
        var claude: [String: OverlayRates] = [:]
        var codex: [String: OverlayRates] = [:]

        if let anthropic = root["anthropic"] as? [String: Any],
           let models = anthropic["models"] as? [String: Any] {
            for (id, value) in models {
                guard let rates = overlayRates(fromModelsDev: value) else { continue }
                let key = normalizeRemoteClaudeID(id)
                guard key.hasPrefix("claude-") else { continue }
                claude[key] = rates
            }
        }
        if let openai = root["openai"] as? [String: Any],
           let models = openai["models"] as? [String: Any] {
            for (id, value) in models {
                guard let rates = overlayRates(fromModelsDev: value) else { continue }
                let key = normalizeRemoteCodexID(id)
                guard key.hasPrefix("gpt-") else { continue }
                codex[key] = rates
            }
        }
        return ProviderBuckets(claude: claude, codex: codex)
    }

    static func parseLiteLLM(_ data: Data) throws -> ProviderBuckets {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.invalidResponse
        }
        var claude: [String: OverlayRates] = [:]
        var codex: [String: OverlayRates] = [:]
        for (rawID, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            let id = rawID
                .replacingOccurrences(of: "anthropic.", with: "")
                .replacingOccurrences(of: "vertex_ai/", with: "")
                .replacingOccurrences(of: "azure_ai/", with: "")
                .replacingOccurrences(of: "openai/", with: "")
            if let at = id.firstIndex(of: "@") {
                let trimmed = String(id[..<at])
                if trimmed.hasPrefix("claude-"), let rates = overlayRates(fromLiteLLM: entry) {
                    claude[trimmed] = rates
                }
                continue
            }
            // Skip regional Bedrock prefixes (us./eu./…) — keep bare Anthropic ids.
            if id.contains("."), !id.hasPrefix("claude-"), !id.hasPrefix("gpt-") { continue }
            if id.hasPrefix("claude-"), let rates = overlayRates(fromLiteLLM: entry) {
                claude[id] = rates
            } else if id.hasPrefix("gpt-"), let rates = overlayRates(fromLiteLLM: entry) {
                codex[normalizeRemoteCodexID(id)] = rates
            }
        }
        return ProviderBuckets(claude: claude, codex: codex)
    }

    private static func overlayRates(fromModelsDev value: Any) -> OverlayRates? {
        guard let model = value as? [String: Any],
              let cost = model["cost"] as? [String: Any],
              let input = double(cost["input"]),
              let output = double(cost["output"]),
              input > 0 || output > 0
        else { return nil }
        return OverlayRates(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheReadPerMillion: double(cost["cache_read"]),
            cacheWritePerMillion: double(cost["cache_write"])
        )
    }

    private static func overlayRates(fromLiteLLM entry: [String: Any]) -> OverlayRates? {
        guard let inputPerToken = double(entry["input_cost_per_token"]),
              let outputPerToken = double(entry["output_cost_per_token"]),
              inputPerToken > 0 || outputPerToken > 0
        else { return nil }
        return OverlayRates(
            inputPerMillion: inputPerToken * 1_000_000,
            outputPerMillion: outputPerToken * 1_000_000,
            cacheReadPerMillion: double(entry["cache_read_input_token_cost"]).map { $0 * 1_000_000 },
            cacheWritePerMillion: double(entry["cache_creation_input_token_cost"]).map { $0 * 1_000_000 }
        )
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    private static func normalizeRemoteClaudeID(_ id: String) -> String {
        var model = id.lowercased()
        if model.hasPrefix("anthropic.") { model = String(model.dropFirst("anthropic.".count)) }
        if let range = model.range(of: #"-\d{8}$"#, options: .regularExpression) {
            model = String(model[..<range.lowerBound])
        }
        return model
    }

    private static func normalizeRemoteCodexID(_ id: String) -> String {
        var model = id.lowercased()
        if model.hasPrefix("openai/") { model = String(model.dropFirst("openai/".count)) }
        if model == "gpt-5.6" { return "gpt-5.6-sol" }
        if model.hasSuffix("-chat-latest") {
            model = String(model.dropLast("-chat-latest".count))
        }
        return model
    }

    private func mergeMissingCacheWrite(into target: inout [String: OverlayRates], from source: [String: OverlayRates]) {
        for (id, rates) in source {
            guard var existing = target[id], existing.cacheWritePerMillion == nil,
                  let write = rates.cacheWritePerMillion else { continue }
            existing.cacheWritePerMillion = write
            if existing.cacheReadPerMillion == nil {
                existing.cacheReadPerMillion = rates.cacheReadPerMillion
            }
            target[id] = existing
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        lock.lock()
        snapshot = decoded
        lock.unlock()
    }

    private func persist(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
