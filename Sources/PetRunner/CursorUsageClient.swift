import Foundation
import PetRunnerCore

/// Cursor dashboard reader. Auth comes from Cursor.app local login and is sent
/// only as an HTTP Cookie header for the request.
///
/// Cursor's usage page totals use plan-metered `chargedCents` (same figure as
/// `get-aggregated-usage-events.totalCostCents`). CodexBar also exposes vendor
/// list-price `tokenUsage.totalCents` separately; PetRunner's ledger stores the
/// metered amount whenever Cursor reports it.
///
/// Session identity (Analytics):
/// - Prefer `conversationId` / `chatId` / `composerId` when the API includes it.
/// - Otherwise chronologically cluster events with a 30-minute idle gap
///   (`CursorSessionGrouping`). Project path/name come from local Cursor IDE
///   state via `CursorLocalSessionIndex`, not a synthetic `"Cursor"` label.
struct CursorUsageClient {
    private let endpoint = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    private let pageSize = 1_000
    private let maximumPages = 200

    func records(cookie: String, now: Date = .now) async throws -> [AgentUsageRecord] {
        var draftsByID: [String: Draft] = [:]
        var expected: Int?
        var received = 0
        for page in 1...maximumPages {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["page": page, "pageSize": pageSize])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CursorUsageClientError.requestFailed
            }
            let payload = try JSONDecoder().decode(Page.self, from: data)
            if let expected, let total = payload.totalUsageEventsCount, expected != total {
                throw CursorUsageClientError.inconsistentPagination
            }
            expected = expected ?? payload.totalUsageEventsCount
            let events = payload.usageEventsDisplay
            received += events.count
            if events.isEmpty {
                guard expected.map({ received >= $0 }) ?? true else {
                    throw CursorUsageClientError.incompletePagination
                }
                return finalize(Array(draftsByID.values))
            }
            for (index, event) in events.enumerated() {
                guard let draft = event.draft(page: page, index: index, fallback: now) else { continue }
                if let existing = draftsByID[draft.record.id], existing.record.tokens.total >= draft.record.tokens.total {
                    continue
                }
                draftsByID[draft.record.id] = draft
            }
            if events.count < pageSize {
                guard expected.map({ received >= $0 }) ?? true else {
                    throw CursorUsageClientError.incompletePagination
                }
                return finalize(Array(draftsByID.values))
            }
        }
        throw CursorUsageClientError.incompletePagination
    }

    private func finalize(_ drafts: [Draft]) -> [AgentUsageRecord] {
        let conversationIDs = Dictionary(uniqueKeysWithValues: drafts.compactMap { draft in
            draft.conversationID.map { (draft.record.id, $0) }
        })
        return CursorSessionGrouping.assignSessionIDs(
            drafts.map(\.record),
            conversationIDs: conversationIDs
        )
    }
}

enum CursorUsageClientError: Error {
    case requestFailed, inconsistentPagination, incompletePagination
}

private struct Draft {
    let record: AgentUsageRecord
    let conversationID: String?
}

private struct Page: Decodable {
    let totalUsageEventsCount: Int?
    let usageEventsDisplay: [Event]
}

private struct Event: Decodable {
    let id: FlexibleString?
    let eventID: FlexibleString?
    let timestamp: FlexibleInt?
    let model: String?
    let kind: String?
    let tokenUsage: TokenUsage?
    let chargedCents: FlexibleDouble?
    let usageBasedCosts: FlexibleString?
    let conversationId: FlexibleString?
    let conversationID: FlexibleString?
    let chatId: FlexibleString?
    let composerId: FlexibleString?

    func draft(page: Int, index: Int, fallback: Date) -> Draft? {
        guard let tokenUsage, tokenUsage.total > 0 else { return nil }
        let occurredAt = timestamp.map {
            Date(timeIntervalSince1970: TimeInterval($0.value) / 1_000)
        } ?? fallback
        // Cursor's usage dashboard totals are plan-metered `chargedCents`
        // (same number as get-aggregated-usage-events.totalCostCents). Vendor
        // list-price `tokenUsage.totalCents` is higher and must not replace a
        // present charged amount, including explicit zeros.
        let cost: UsageCost
        if let charged = chargedCents?.value {
            cost = UsageCost(usd: charged / 100, provenance: .providerReported)
        } else if let apiCost = tokenUsage.totalCents?.value, apiCost > 0 {
            cost = UsageCost(usd: apiCost / 100, provenance: .estimated, isBudgetEligible: false)
        } else {
            cost = UsageCost(usd: nil, provenance: .unavailable, isBudgetEligible: false)
        }
        // Events have no stable API id; token counts grow while a request is
        // open. Key only on timestamp + model so refresh replaces the row.
        let identity = id?.value.nilIfEmpty
            ?? eventID?.value.nilIfEmpty
            ?? "\(timestamp?.value ?? 0):\(model ?? "unknown")"
        let conversation = conversationId?.value.nilIfEmpty
            ?? conversationID?.value.nilIfEmpty
            ?? chatId?.value.nilIfEmpty
            ?? composerId?.value.nilIfEmpty
        // Temporary session id; `CursorSessionGrouping` rewrites after fetch.
        let record = AgentUsageRecord(
            id: "cursor:\(identity)",
            provider: .cursor,
            sessionID: "pending",
            occurredAt: occurredAt,
            model: model,
            tokens: .init(
                input: tokenUsage.inputTokens,
                cachedInput: tokenUsage.cacheReadTokens,
                cacheCreation: tokenUsage.cacheWriteTokens,
                output: tokenUsage.outputTokens
            ),
            cost: cost,
            usageType: Self.billingType(kind: kind, usageBasedCosts: usageBasedCosts?.value)
        )
        return Draft(record: record, conversationID: conversation)
    }

    /// Maps Cursor event `kind` / `usageBasedCosts` onto Included vs On-demand.
    /// Included-plan rows still carry metered `chargedCents`; overage is detected
    /// via usage-based kind or a positive `usageBasedCosts` dollar string.
    static func billingType(kind: String?, usageBasedCosts: String?) -> UsageBillingType {
        let trimmedCosts = usageBasedCosts?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCosts, trimmedCosts != "-", trimmedCosts != "0",
           let value = Double(trimmedCosts), value > 0 {
            return .onDemand
        }
        let normalized = (kind ?? "").uppercased()
        if normalized.contains("USAGE_BASED") || normalized.contains("ON_DEMAND") || normalized.contains("ONDEMAND") {
            return .onDemand
        }
        if normalized.contains("INCLUDED") {
            return .included
        }
        return .included
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Lenient token payload: Cursor omits zero-valued fields such as `cacheWriteTokens`
/// on most events, so required Int decoding would fail the entire page.
private struct TokenUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    let totalCents: FlexibleDouble?

    var total: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens, totalCents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = Self.int(container, .inputTokens)
        outputTokens = Self.int(container, .outputTokens)
        cacheWriteTokens = Self.int(container, .cacheWriteTokens)
        cacheReadTokens = Self.int(container, .cacheReadTokens)
        totalCents = try container.decodeIfPresent(FlexibleDouble.self, forKey: .totalCents)
    }

    private static func int(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(Double.self, forKey: key) { return Int(value) }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int(value) ?? Int(Double(value) ?? 0)
        }
        return 0
    }
}

private struct FlexibleInt: Decodable {
    let value: Int
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = value
        } else if let value = try? container.decode(Double.self) {
            self.value = Int(value)
        } else if let value = try? container.decode(String.self) {
            self.value = Int(value) ?? Int(Double(value) ?? 0)
        } else {
            self.value = 0
        }
    }
}

private struct FlexibleDouble: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self), value.isFinite {
            self.value = value
        } else if let value = try? container.decode(Int.self) {
            self.value = Double(value)
        } else if let value = try? container.decode(String.self), let parsed = Double(value), parsed.isFinite {
            self.value = parsed
        } else {
            self.value = 0
        }
    }
}

private struct FlexibleString: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = (try? container.decode(String.self))
            ?? (try? container.decode(Int.self)).map(String.init)
            ?? (try? container.decode(Double.self)).map { String(Int($0)) }
            ?? ""
    }
}
