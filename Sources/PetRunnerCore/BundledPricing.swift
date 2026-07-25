import Foundation

public enum BundledPricing {
    /// Offline baseline aligned with models.dev / LiteLLM (no long-context
    /// surcharge tiers, matching ccgauge `costFromUsage`). Remote refresh via
    /// `PricingCatalogStore` layers newer model ids + rates on top.
    public static let bundledVersion = "2026-07-25-codex"

    /// Active catalog version (bundled, or bundled + remote overlay stamp).
    /// Included in historical parser receipts so pricing refreshes rebuild costs.
    public static var version: String { PricingCatalogStore.shared.effectiveVersion }

    public struct ResolvedRates: Equatable, Sendable {
        public let input: Double
        public let cachedInput: Double?
        public let cacheCreation: Double?
        public let output: Double
    }

    /// JSON-friendly catalog row for the Providers → Pricing panel.
    /// Rates are USD per 1M tokens (API-equivalent), matching Analytics model cards.
    public struct CatalogEntry: Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let provider: UsageProvider
        public let inputPerMillionUSD: Double
        public let outputPerMillionUSD: Double
        public let cacheReadPerMillionUSD: Double?
        public let cacheWritePerMillionUSD: Double?
        public let contextThreshold: Int?
        public let inputAboveThresholdPerMillionUSD: Double?
        public let outputAboveThresholdPerMillionUSD: Double?
        public let cacheReadAboveThresholdPerMillionUSD: Double?
        public let cacheWriteAboveThresholdPerMillionUSD: Double?
    }

    fileprivate struct Rates {
        let input: Double
        let cachedInput: Double?
        let cacheCreation: Double?
        let output: Double
        let threshold: Int?
        let inputAboveThreshold: Double?
        let cachedInputAboveThreshold: Double?
        let cacheCreationAboveThreshold: Double?
        let outputAboveThreshold: Double?
    }

    /// Anthropic Sonnet 5 intro pricing ends 2026-08-31; standard $3/$15 from 2026-09-01 UTC.
    fileprivate static let sonnet5StandardRatesStart = Date(timeIntervalSince1970: 1_788_220_800)

    private static let codexRates: [String: Rates] = [
        "gpt-5": .init(input: 1.25e-6, cachedInput: 1.25e-7, cacheCreation: nil, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5-codex": .init(input: 1.25e-6, cachedInput: 1.25e-7, cacheCreation: nil, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5-mini": .init(input: 2.5e-7, cachedInput: 2.5e-8, cacheCreation: nil, output: 2e-6, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5-nano": .init(input: 5e-8, cachedInput: 5e-9, cacheCreation: nil, output: 4e-7, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5-pro": .init(input: 1.5e-5, cachedInput: nil, cacheCreation: nil, output: 1.2e-4, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.1": .init(input: 1.25e-6, cachedInput: 1.25e-7, cacheCreation: nil, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.1-codex": .init(input: 1.25e-6, cachedInput: 1.25e-7, cacheCreation: nil, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.1-codex-max": .init(input: 1.25e-6, cachedInput: 1.25e-7, cacheCreation: nil, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.1-codex-mini": .init(input: 2.5e-7, cachedInput: 2.5e-8, cacheCreation: nil, output: 2e-6, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.2": .init(input: 1.75e-6, cachedInput: 1.75e-7, cacheCreation: nil, output: 1.4e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.2-codex": .init(input: 1.75e-6, cachedInput: 1.75e-7, cacheCreation: nil, output: 1.4e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.3-codex": .init(input: 1.75e-6, cachedInput: 1.75e-7, cacheCreation: nil, output: 1.4e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.3-codex-spark": .init(input: 0, cachedInput: 0, cacheCreation: 0, output: 0, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.4": .init(input: 2.5e-6, cachedInput: 2.5e-7, cacheCreation: nil, output: 1.5e-5, threshold: 272_000, inputAboveThreshold: 5e-6, cachedInputAboveThreshold: 5e-7, cacheCreationAboveThreshold: nil, outputAboveThreshold: 2.25e-5),
        "gpt-5.4-mini": .init(input: 7.5e-7, cachedInput: 7.5e-8, cacheCreation: nil, output: 4.5e-6, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.4-nano": .init(input: 2e-7, cachedInput: 2e-8, cacheCreation: nil, output: 1.25e-6, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.4-pro": .init(input: 3e-5, cachedInput: nil, cacheCreation: nil, output: 1.8e-4, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.5": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: nil, output: 3e-5, threshold: 272_000, inputAboveThreshold: 1e-5, cachedInputAboveThreshold: 1e-6, cacheCreationAboveThreshold: nil, outputAboveThreshold: 4.5e-5),
        "gpt-5.5-pro": .init(input: 3e-5, cachedInput: nil, cacheCreation: nil, output: 1.8e-4, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "gpt-5.6-sol": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 3e-5, threshold: 272_000, inputAboveThreshold: 1e-5, cachedInputAboveThreshold: 1e-6, cacheCreationAboveThreshold: 1.25e-5, outputAboveThreshold: 4.5e-5),
        "gpt-5.6-terra": .init(input: 2.5e-6, cachedInput: 2.5e-7, cacheCreation: 3.125e-6, output: 1.5e-5, threshold: 272_000, inputAboveThreshold: 5e-6, cachedInputAboveThreshold: 5e-7, cacheCreationAboveThreshold: 6.25e-6, outputAboveThreshold: 2.25e-5),
        "gpt-5.6-luna": .init(input: 1e-6, cachedInput: 1e-7, cacheCreation: 1.25e-6, output: 6e-6, threshold: 272_000, inputAboveThreshold: 2e-6, cachedInputAboveThreshold: 2e-7, cacheCreationAboveThreshold: 2.5e-6, outputAboveThreshold: 9e-6),
    ]

    private static let claudeRates: [String: Rates] = [
        "claude-fable-5": .init(input: 1e-5, cachedInput: 1e-6, cacheCreation: 1.25e-5, output: 5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-mythos-5": .init(input: 1e-5, cachedInput: 1e-6, cacheCreation: 1.25e-5, output: 5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-haiku-4-5": .init(input: 1e-6, cachedInput: 1e-7, cacheCreation: 1.25e-6, output: 5e-6, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4": .init(input: 1.5e-5, cachedInput: 1.5e-6, cacheCreation: 1.875e-5, output: 7.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4-1": .init(input: 1.5e-5, cachedInput: 1.5e-6, cacheCreation: 1.875e-5, output: 7.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4-5": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 2.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4-6": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 2.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4-7": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 2.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-4-8": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 2.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-opus-5": .init(input: 5e-6, cachedInput: 5e-7, cacheCreation: 6.25e-6, output: 2.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        // Intro $2/$10 through 2026-08-31; `sonnet5Rates(at:)` upgrades to $3/$15 afterwards.
        "claude-sonnet-5": .init(input: 2e-6, cachedInput: 2e-7, cacheCreation: 2.5e-6, output: 1e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
        "claude-sonnet-4": .init(input: 3e-6, cachedInput: 3e-7, cacheCreation: 3.75e-6, output: 1.5e-5, threshold: 200_000, inputAboveThreshold: 6e-6, cachedInputAboveThreshold: 6e-7, cacheCreationAboveThreshold: 7.5e-6, outputAboveThreshold: 2.25e-5),
        "claude-sonnet-4-5": .init(input: 3e-6, cachedInput: 3e-7, cacheCreation: 3.75e-6, output: 1.5e-5, threshold: 200_000, inputAboveThreshold: 6e-6, cachedInputAboveThreshold: 6e-7, cacheCreationAboveThreshold: 7.5e-6, outputAboveThreshold: 2.25e-5),
        "claude-sonnet-4-6": .init(input: 3e-6, cachedInput: 3e-7, cacheCreation: 3.75e-6, output: 1.5e-5, threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil, cacheCreationAboveThreshold: nil, outputAboveThreshold: nil),
    ]

    // Long-context surcharge tables intentionally omitted to match ccgauge
    // (LiteLLM snapshot drops `*_above_200k` tiers). Remote refresh may still
    // list base rates for models that appear after this bundle ships.

    /// API-equivalent calculated cost matching ccgauge `costFromUsage`.
    /// Unknown Claude/Codex models fall back to the latest family rates;
    /// otherwise unpriced. Remote overlay rates win over the offline bundle.
    public static func cost(model: String?, tokens: UsageTokenBreakdown, occurredAt: Date? = nil) -> UsageCost {
        let at = occurredAt ?? .now
        guard let rawModel = model?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !rawModel.isEmpty else {
            return UsageCost(usd: nil, provenance: .unavailable)
        }
        if let rates = resolveClaudeRates(rawModel, at: at) {
            return calculated(claudeCost(rates: rates, tokens: tokens), version: version)
        }
        if let rates = resolveCodexRates(rawModel) {
            return calculated(codexCost(rates: rates, tokens: tokens), version: version)
        }
        return UsageCost(usd: nil, provenance: .unavailable)
    }

    /// Catalog rates for Analytics model cards. Returns nil for unknown models
    /// (shown as "fallback price" in the UI).
    public static func resolved(model: String?) -> ResolvedRates? {
        guard let rawModel = model?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !rawModel.isEmpty else {
            return nil
        }
        guard let rates = resolveClaudeRates(rawModel, at: .now) ?? resolveCodexRates(rawModel) else { return nil }
        return ResolvedRates(input: rates.input, cachedInput: rates.cachedInput, cacheCreation: rates.cacheCreation, output: rates.output)
    }

    /// Approximate dollars saved by reading cache instead of paying full input
    /// (ccgauge `saved` = cache_read * (input - cacheRead)).
    public static func cacheSavingsUSD(model: String?, tokens: UsageTokenBreakdown) -> Double {
        guard let rates = resolved(model: model), tokens.cachedInput > 0 else { return 0 }
        let cacheRate = rates.cachedInput ?? rates.input
        return max(0, Double(tokens.cachedInput) * (rates.input - cacheRate))
    }

    public static func shortDisplayName(_ model: String) -> String {
        var value = model
        if value.hasPrefix("openai/") { value = String(value.dropFirst("openai/".count)) }
        if value.hasPrefix("anthropic.") { value = String(value.dropFirst("anthropic.".count)) }
        if let range = value.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            value = String(value[..<range.lowerBound])
        }
        if let range = value.range(of: #"-\d{8}$"#, options: .regularExpression) {
            value = String(value[..<range.lowerBound])
        }
        return value
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part -> String in
                let text = String(part)
                if text.lowercased().hasPrefix("gpt") { return text.uppercased() }
                return text.prefix(1).uppercased() + text.dropFirst()
            }
            .joined(separator: " ")
    }

    /// Full Claude/Codex rate catalog used for local cost calculation.
    /// Cursor has no local rates (provider-reported `chargedCents`).
    public static func catalog(provider: UsageProvider? = nil) -> [CatalogEntry] {
        var entries: [CatalogEntry] = []
        if provider == nil || provider == .claude {
            let ids = Set(claudeRates.keys).union(PricingCatalogStore.shared.overlayClaudeModels())
            entries.append(contentsOf: ids.sorted().compactMap { id in
                guard let rates = resolveClaudeRates(id, at: .now) else { return nil }
                return catalogEntry(id: id, provider: .claude, rates: rates)
            })
        }
        if provider == nil || provider == .codex {
            let ids = Set(codexRates.keys).union(PricingCatalogStore.shared.overlayCodexModels())
            entries.append(contentsOf: ids.sorted().compactMap { id in
                guard let rates = resolveCodexRates(id) else { return nil }
                return catalogEntry(id: id, provider: .codex, rates: rates)
            })
        }
        return entries
    }

    public static var catalogSource: String { PricingCatalogStore.shared.sourceLabel }
    public static var catalogLabel: String { PricingCatalogStore.shared.catalogLabel }

    private static func catalogEntry(id: String, provider: UsageProvider, rates: Rates) -> CatalogEntry {
        CatalogEntry(
            id: id,
            displayName: shortDisplayName(id),
            provider: provider,
            inputPerMillionUSD: rates.input * 1_000_000,
            outputPerMillionUSD: rates.output * 1_000_000,
            cacheReadPerMillionUSD: rates.cachedInput.map { $0 * 1_000_000 },
            cacheWritePerMillionUSD: rates.cacheCreation.map { $0 * 1_000_000 },
            contextThreshold: rates.threshold,
            inputAboveThresholdPerMillionUSD: rates.inputAboveThreshold.map { $0 * 1_000_000 },
            outputAboveThresholdPerMillionUSD: rates.outputAboveThreshold.map { $0 * 1_000_000 },
            cacheReadAboveThresholdPerMillionUSD: rates.cachedInputAboveThreshold.map { $0 * 1_000_000 },
            cacheWriteAboveThresholdPerMillionUSD: rates.cacheCreationAboveThreshold.map { $0 * 1_000_000 }
        )
    }

    private static func calculated(_ value: Double, version: String) -> UsageCost {
        UsageCost(usd: value, provenance: .calculated, pricingVersion: version)
    }

    /// ccgauge Codex path: bill non-cached input + cache read + output at base
    /// rates only. Long-context / priority tiers are omitted (ccgauge drops them).
    private static func codexCost(rates: Rates, tokens: UsageTokenBreakdown) -> Double {
        let totalInput = tokens.input
        let cached = min(tokens.cachedInput, totalInput)
        let cacheCreation = min(tokens.cacheCreation, totalInput - cached)
        let normal = totalInput - cached - cacheCreation
        let cachedRate = rates.cachedInput ?? rates.input
        let creationRate = rates.cacheCreation ?? rates.input
        return Double(normal) * rates.input
            + Double(cached) * cachedRate
            + Double(cacheCreation) * creationRate
            + Double(tokens.output) * rates.output
    }

    /// ccgauge `costFromUsage`: input + output + cacheCreation5m + cacheCreation1h + cacheRead.
    /// 1h writes use 2× input (LiteLLM only publishes 5m write cost). No 200k tiers.
    private static func claudeCost(rates: Rates, tokens: UsageTokenBreakdown) -> Double {
        let cachedRate = rates.cachedInput ?? rates.input
        let creation5mRate = rates.cacheCreation ?? rates.input
        let creation1hRate = rates.input * 2
        let creation1h = min(tokens.cacheCreation1h, tokens.cacheCreation)
        let creation5m = tokens.cacheCreation - creation1h
        return Double(tokens.input) * rates.input
            + Double(tokens.output) * rates.output
            + Double(creation5m) * creation5mRate
            + Double(creation1h) * creation1hRate
            + Double(tokens.cachedInput) * cachedRate
    }

    private static func resolveClaudeRates(_ rawModel: String, at date: Date) -> Rates? {
        let model = normalizeClaudeModel(rawModel)
        if let overlay = PricingCatalogStore.shared.claudeOverlay(for: model) {
            return rates(from: overlay)
        }
        if isSonnet5Family(model) {
            return sonnet5Rates(at: date)
        }
        if let rates = claudeRates[model] { return rates }
        // Latest family fallback (prefer Sonnet 5 / Opus 5 when present).
        for family in ["mythos", "fable", "opus", "sonnet", "haiku"] where model.contains(family) {
            let fallbackKey: String
            switch family {
            case "mythos": fallbackKey = "claude-mythos-5"
            case "fable": fallbackKey = "claude-fable-5"
            case "opus": fallbackKey = "claude-opus-5"
            case "sonnet": fallbackKey = "claude-sonnet-5"
            default: fallbackKey = "claude-haiku-4-5"
            }
            if fallbackKey == "claude-sonnet-5" {
                return sonnet5Rates(at: date)
            }
            if let rates = claudeRates[fallbackKey] { return rates }
        }
        return nil
    }

    private static func isSonnet5Family(_ model: String) -> Bool {
        model == "claude-sonnet-5" || model.hasPrefix("claude-sonnet-5-")
    }

    private static func sonnet5Rates(at date: Date) -> Rates {
        if date >= sonnet5StandardRatesStart {
            return .init(
                input: 3e-6, cachedInput: 3e-7, cacheCreation: 3.75e-6, output: 1.5e-5,
                threshold: nil, inputAboveThreshold: nil, cachedInputAboveThreshold: nil,
                cacheCreationAboveThreshold: nil, outputAboveThreshold: nil
            )
        }
        return claudeRates["claude-sonnet-5"]!
    }

    private static func resolveCodexRates(_ rawModel: String) -> Rates? {
        let model = normalizeCodexModel(rawModel)
        if let overlay = PricingCatalogStore.shared.codexOverlay(for: model) {
            return rates(from: overlay)
        }
        if let rates = codexRates[model] { return rates }
        if model.hasPrefix("gpt-") || model == "gpt" {
            return PricingCatalogStore.shared.codexOverlay(for: "gpt-5.5").map(rates(from:))
                ?? codexRates["gpt-5.5"]
        }
        if model.range(of: #"^o\d"#, options: .regularExpression) != nil {
            return nil
        }
        return nil
    }

    private static func rates(from overlay: PricingCatalogStore.OverlayRates) -> Rates {
        Rates(
            input: overlay.inputPerMillion / 1_000_000,
            cachedInput: overlay.cacheReadPerMillion.map { $0 / 1_000_000 },
            cacheCreation: overlay.cacheWritePerMillion.map { $0 / 1_000_000 },
            output: overlay.outputPerMillion / 1_000_000,
            threshold: nil,
            inputAboveThreshold: nil,
            cachedInputAboveThreshold: nil,
            cacheCreationAboveThreshold: nil,
            outputAboveThreshold: nil
        )
    }

    private static func normalizeCodexModel(_ model: String) -> String {
        var model = model.hasPrefix("openai/") ? String(model.dropFirst("openai/".count)) : model
        if model == "gpt-5.6" { return "gpt-5.6-sol" }
        // models.dev ChatGPT aliases (gpt-5.3-chat-latest → gpt-5.3 → gpt-5.3-codex).
        if model.hasSuffix("-chat-latest") {
            model = String(model.dropLast("-chat-latest".count))
        }
        if let dateRange = model.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(model[..<dateRange.lowerBound])
            if knownCodexRate(base) { model = base }
        }
        if !knownCodexRate(model), !model.hasSuffix("-codex") {
            let codexVariant = "\(model)-codex"
            if knownCodexRate(codexVariant) { return codexVariant }
        }
        return model
    }

    private static func knownCodexRate(_ id: String) -> Bool {
        codexRates[id] != nil || PricingCatalogStore.shared.codexOverlay(for: id) != nil
    }

    private static func normalizeClaudeModel(_ model: String) -> String {
        var model = model.hasPrefix("anthropic.") ? String(model.dropFirst("anthropic.".count)) : model
        if let dot = model.lastIndex(of: ".") {
            let tail = String(model[model.index(after: dot)...])
            if tail.hasPrefix("claude-") { model = tail }
        }
        if let versionRange = model.range(of: #"-v\d+:\d+$"#, options: .regularExpression) { model.removeSubrange(versionRange) }
        if let dateRange = model.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(model[..<dateRange.lowerBound])
            if claudeRates[base] != nil || PricingCatalogStore.shared.claudeOverlay(for: base) != nil || isSonnet5Family(base) {
                model = base
            }
        }
        return model
    }
}

