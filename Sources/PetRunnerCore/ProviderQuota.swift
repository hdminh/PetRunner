import Foundation

/// CodexBar-style rate-limit window (percent used + optional reset).
public struct RateWindow: Equatable, Sendable, Codable {
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?
    public var label: String?

    public init(usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil, label: String? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.label = label
    }

    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

public struct ProviderMonthlySpendQuota: Equatable, Sendable, Codable {
    public var usedUSD: Double
    public var limitUSD: Double?
    public var resetsAt: Date?

    public init(usedUSD: Double, limitUSD: Double? = nil, resetsAt: Date? = nil) {
        self.usedUSD = usedUSD
        self.limitUSD = limitUSD
        self.resetsAt = resetsAt
    }
}

/// Plan quota snapshot for one provider (separate from spend ledger / user budgets).
public struct ProviderQuotaSnapshot: Equatable, Sendable, Codable {
    public var primary: RateWindow?
    public var secondary: RateWindow?
    public var tertiary: RateWindow?
    public var monthlySpend: ProviderMonthlySpendQuota?
    public var source: String
    public var updatedAt: Date
    public var message: String?

    public init(
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        monthlySpend: ProviderMonthlySpendQuota? = nil,
        source: String,
        updatedAt: Date = .now,
        message: String? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.monthlySpend = monthlySpend
        self.source = source
        self.updatedAt = updatedAt
        self.message = message
    }

    public static func unavailable(source: String, message: String, updatedAt: Date = .now) -> Self {
        Self(source: source, updatedAt: updatedAt, message: message)
    }
}

public enum ProviderQuotaParser {
    public static let sessionMinutes = 300
    public static let weeklyMinutes = 10_080

    /// Claude OAuth / web usage payload (`five_hour`, `seven_day`, `extra_usage`).
    public static func parseClaudeUsage(_ object: [String: Any], now: Date = .now) -> ProviderQuotaSnapshot {
        let primary = rateWindow(object["five_hour"], minutes: sessionMinutes, label: "Session")
            ?? rateWindow(object["session"], minutes: sessionMinutes, label: "Session")
        let secondary = rateWindow(object["seven_day"], minutes: weeklyMinutes, label: "Weekly")
            ?? rateWindow(object["week"], minutes: weeklyMinutes, label: "Weekly")
        let tertiary = rateWindow(object["seven_day_sonnet"], minutes: weeklyMinutes, label: "Weekly Sonnet")
            ?? rateWindow(object["seven_day_opus"], minutes: weeklyMinutes, label: "Weekly Opus")
        let monthly = extraUsage(object["extra_usage"])
        return ProviderQuotaSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            monthlySpend: monthly,
            source: "oauth",
            updatedAt: now
        )
    }

    /// Codex / ChatGPT `wham/usage` rate_limit windows.
    public static func parseCodexWhamUsage(_ object: [String: Any], now: Date = .now) -> ProviderQuotaSnapshot {
        let rateLimit = object["rate_limit"] as? [String: Any] ?? object
        var primary = windowSnapshot(rateLimit["primary_window"], fallbackMinutes: sessionMinutes, label: "Session")
        var secondary = windowSnapshot(rateLimit["secondary_window"], fallbackMinutes: weeklyMinutes, label: "Weekly")
        // CodexBar normalizer: swap if API flips session/weekly by duration.
        if let left = primary?.windowMinutes, let right = secondary?.windowMinutes,
           left > weeklyMinutes / 2, right <= sessionMinutes + 30 {
            swap(&primary, &secondary)
            primary?.label = "Session"
            secondary?.label = "Weekly"
        }
        let monthly: ProviderMonthlySpendQuota?
        if let individual = object["individual_limit"] as? [String: Any]
            ?? rateLimit["individual_limit"] as? [String: Any] {
            let used = doubleValue(individual["used"]) ?? doubleValue(individual["spent"]) ?? 0
            let limit = doubleValue(individual["limit"]) ?? doubleValue(individual["allowed"])
            monthly = ProviderMonthlySpendQuota(usedUSD: used, limitUSD: limit)
        } else {
            monthly = nil
        }
        return ProviderQuotaSnapshot(
            primary: primary,
            secondary: secondary,
            monthlySpend: monthly,
            source: "oauth",
            updatedAt: now
        )
    }

    /// Cursor `usage-summary` billing-cycle meters.
    ///
    /// Current Cursor payloads nest meters under `individualUsage.plan` /
    /// `individualUsage.onDemand`. Older shapes exposed the same fields at the
    /// top level; both are accepted.
    public static func parseCursorUsageSummary(_ object: [String: Any], now: Date = .now) -> ProviderQuotaSnapshot {
        let billingEnd = dateValue(object["billingCycleEnd"]) ?? dateValue(object["billing_cycle_end"])
        let billingStart = dateValue(object["billingCycleStart"]) ?? dateValue(object["billing_cycle_start"])
        let windowMinutes: Int?
        if let start = billingStart, let end = billingEnd {
            windowMinutes = max(1, Int(end.timeIntervalSince(start) / 60))
        } else {
            windowMinutes = nil
        }

        let individualUsage = object["individualUsage"] as? [String: Any]
            ?? object["individual_usage"] as? [String: Any]
        let plan = individualUsage?["plan"] as? [String: Any]
            ?? object["plan"] as? [String: Any]
        let teamUsage = object["teamUsage"] as? [String: Any]
            ?? object["team_usage"] as? [String: Any]

        let primaryPercent = doubleValue(plan?["totalPercentUsed"])
            ?? doubleValue(plan?["total_percent_used"])
            ?? doubleValue(object["totalPercentUsed"])
            ?? doubleValue(object["total_percent_used"])
            ?? percentFromCents(used: plan?["used"], limit: plan?["limit"])
            ?? percentFromCents(used: object["used"], limit: object["limit"])
        let autoPercent = doubleValue(plan?["autoPercentUsed"])
            ?? doubleValue(plan?["auto_percent_used"])
            ?? doubleValue(object["autoPercentUsed"])
            ?? doubleValue(object["auto_percent_used"])
        let apiPercent = doubleValue(plan?["apiPercentUsed"])
            ?? doubleValue(plan?["api_percent_used"])
            ?? doubleValue(object["apiPercentUsed"])
            ?? doubleValue(object["api_percent_used"])

        let primary = primaryPercent.map {
            RateWindow(usedPercent: $0, windowMinutes: windowMinutes, resetsAt: billingEnd, label: "Included")
        }
        let secondary = autoPercent.map {
            RateWindow(usedPercent: $0, windowMinutes: windowMinutes, resetsAt: billingEnd, label: "Auto")
        }
        let tertiary = apiPercent.map {
            RateWindow(usedPercent: $0, windowMinutes: windowMinutes, resetsAt: billingEnd, label: "API")
        }

        let individualOnDemand = individualUsage?["onDemand"] as? [String: Any]
            ?? individualUsage?["on_demand"] as? [String: Any]
            ?? object["onDemand"] as? [String: Any]
            ?? object["on_demand"] as? [String: Any]
        let teamOnDemand = teamUsage?["onDemand"] as? [String: Any]
            ?? teamUsage?["on_demand"] as? [String: Any]
        // Prefer individual on-demand; when it has no cap, fall back to team.
        let onDemand: [String: Any]?
        if let individualOnDemand {
            let individualLimit = centsToUSD(individualOnDemand["limit"]) ?? doubleValue(individualOnDemand["limit"])
            if individualLimit != nil {
                onDemand = individualOnDemand
            } else {
                onDemand = teamOnDemand ?? individualOnDemand
            }
        } else {
            onDemand = teamOnDemand
        }

        let monthly: ProviderMonthlySpendQuota?
        if let onDemand {
            let used = centsToUSD(onDemand["used"]) ?? doubleValue(onDemand["used"]) ?? 0
            let limit = centsToUSD(onDemand["limit"]) ?? doubleValue(onDemand["limit"])
            monthly = ProviderMonthlySpendQuota(usedUSD: used, limitUSD: limit, resetsAt: billingEnd)
        } else {
            monthly = nil
        }

        let hasMeters = primary != nil || secondary != nil || tertiary != nil || monthly != nil
        return ProviderQuotaSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            monthlySpend: monthly,
            source: "localAuth",
            updatedAt: now,
            message: hasMeters ? nil : "Cursor returned usage summary without plan meters."
        )
    }

    private static func rateWindow(_ value: Any?, minutes: Int, label: String) -> RateWindow? {
        guard let object = value as? [String: Any] else { return nil }
        guard let utilization = doubleValue(object["utilization"]) ?? doubleValue(object["used_percent"])
            ?? doubleValue(object["usedPercent"])
        else { return nil }
        return RateWindow(
            usedPercent: utilization,
            windowMinutes: minutes,
            resetsAt: dateValue(object["resets_at"]) ?? dateValue(object["resetsAt"]),
            label: label
        )
    }

    private static func windowSnapshot(_ value: Any?, fallbackMinutes: Int, label: String) -> RateWindow? {
        guard let object = value as? [String: Any] else { return nil }
        guard let used = doubleValue(object["used_percent"]) ?? doubleValue(object["usedPercent"])
            ?? doubleValue(object["utilization"])
        else { return nil }
        let seconds = doubleValue(object["limit_window_seconds"]) ?? doubleValue(object["limitWindowSeconds"])
        let minutes = seconds.map { Int($0 / 60) } ?? fallbackMinutes
        let resetsAt = dateValue(object["reset_at"])
            ?? dateValue(object["resetAt"])
            ?? dateValue(object["resets_at"])
        return RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt, label: label)
    }

    private static func extraUsage(_ value: Any?) -> ProviderMonthlySpendQuota? {
        guard let object = value as? [String: Any] else { return nil }
        let enabled = object["is_enabled"] as? Bool ?? object["isEnabled"] as? Bool ?? true
        guard enabled else { return nil }
        let used = doubleValue(object["used_credits"]) ?? doubleValue(object["usedCredits"]) ?? 0
        let limit = doubleValue(object["monthly_limit"]) ?? doubleValue(object["monthlyLimit"])
        return ProviderMonthlySpendQuota(usedUSD: used, limitUSD: limit)
    }

    private static func percentFromCents(used: Any?, limit: Any?) -> Double? {
        guard let usedCents = doubleValue(used), let limitCents = doubleValue(limit), limitCents > 0 else { return nil }
        return (usedCents / limitCents) * 100
    }

    private static func centsToUSD(_ value: Any?) -> Double? {
        doubleValue(value).map { $0 / 100 }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let raw = number.doubleValue
            // Heuristic: unix seconds vs milliseconds.
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = Double(trimmed) {
                return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: trimmed) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: trimmed)
        }
        return nil
    }
}
