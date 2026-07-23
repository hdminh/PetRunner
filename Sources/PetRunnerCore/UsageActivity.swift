import Foundation

/// Lifetime coding-rhythm stats (ccgauge `computeActivityStats`).
/// Heatmap is day-of-week × hour-of-day in the local calendar (Sun=0 … Sat=6).
public struct UsageActivityStats: Equatable, Sendable {
    public let activeDays: Int
    public let currentStreak: Int
    public let longestStreak: Int
    /// Peak local hour `0...23`, or `-1` when there is no activity.
    public let peakHour: Int
    public let requestCount: Int
    public let totalTokens: Int
    /// Request counts: `heatmap[dow][hour]`.
    public let heatmap: [[Int]]
    public let heatmapMax: Int
    /// Token totals per cell (same shape as `heatmap`).
    public let tokenHeatmap: [[Int]]
    public let comparison: TokenComparison?

    public struct TokenComparison: Equatable, Sendable {
        public let refKey: String
        public let label: String
        public let multiplier: Double

        public init(refKey: String, label: String, multiplier: Double) {
            self.refKey = refKey
            self.label = label
            self.multiplier = multiplier
        }
    }
}

/// Aggregates usage ledger records into Activity KPIs + week×hour heatmaps.
public enum UsageActivityAggregator {
    public static let defaultStreakWindowDays = 365

    public static func stats(
        from records: [AgentUsageRecord],
        calendar: Calendar = .current,
        now: Date = .now,
        streakWindowDays: Int = defaultStreakWindowDays
    ) -> UsageActivityStats {
        guard !records.isEmpty else {
            return emptyStats()
        }

        var dayKeys = Set<String>()
        var hourCounts = Array(repeating: 0, count: 24)
        var heatmap = emptyHeatmap()
        var tokenHeatmap = emptyHeatmap()
        var totalTokens = 0
        var requestCount = 0

        for record in records {
            let date = record.occurredAt
            dayKeys.insert(dayKey(for: date, calendar: calendar))
            let weekday = calendar.component(.weekday, from: date) // 1=Sun … 7=Sat
            let dow = max(0, min(6, weekday - 1))
            let hour = calendar.component(.hour, from: date)
            hourCounts[hour] += 1
            heatmap[dow][hour] += 1
            let tokens = record.totalTokens
            tokenHeatmap[dow][hour] += tokens
            totalTokens += tokens
            requestCount += 1
        }

        let peakHour = argMax(hourCounts)
        let streaks = computeStreaks(dayKeys: dayKeys, windowDays: streakWindowDays, calendar: calendar, now: now)
        var heatmapMax = 0
        for row in heatmap {
            for value in row where value > heatmapMax {
                heatmapMax = value
            }
        }

        return UsageActivityStats(
            activeDays: dayKeys.count,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            peakHour: peakHour,
            requestCount: requestCount,
            totalTokens: totalTokens,
            heatmap: heatmap,
            heatmapMax: heatmapMax,
            tokenHeatmap: tokenHeatmap,
            comparison: pickTokenComparison(totalTokens: totalTokens)
        )
    }

    public static func pickTokenComparison(totalTokens: Int) -> UsageActivityStats.TokenComparison? {
        guard totalTokens > 0 else { return nil }
        var chosen = references[0]
        for reference in references {
            if Double(totalTokens) / Double(reference.tokens) >= 5 {
                chosen = reference
            }
        }
        return UsageActivityStats.TokenComparison(
            refKey: chosen.key,
            label: chosen.label,
            multiplier: Double(totalTokens) / Double(chosen.tokens)
        )
    }

    // MARK: - Internals

    private struct Reference {
        let key: String
        let label: String
        let tokens: Int
    }

    private static let references: [Reference] = [
        .init(key: "haiku", label: "a haiku", tokens: 22),
        .init(key: "tweet", label: "a tweet", tokens: 50),
        .init(key: "littlePrince", label: "The Little Prince", tokens: 22_000),
        .init(key: "gatsby", label: "The Great Gatsby", tokens: 65_000),
        .init(key: "hobbit", label: "The Hobbit", tokens: 124_000),
        .init(key: "lotrTrilogy", label: "the Lord of the Rings trilogy", tokens: 624_000),
        .init(key: "warAndPeace", label: "War and Peace", tokens: 763_000),
        .init(key: "harryPotterAll", label: "all 7 Harry Potter books", tokens: 1_430_000),
        .init(key: "encyclopediaBritannica", label: "the Encyclopedia Britannica", tokens: 57_200_000),
        .init(key: "wikipediaEn", label: "all of English Wikipedia", tokens: 6_500_000_000),
    ]

    private static func emptyStats() -> UsageActivityStats {
        UsageActivityStats(
            activeDays: 0,
            currentStreak: 0,
            longestStreak: 0,
            peakHour: -1,
            requestCount: 0,
            totalTokens: 0,
            heatmap: emptyHeatmap(),
            heatmapMax: 0,
            tokenHeatmap: emptyHeatmap(),
            comparison: nil
        )
    }

    private static func emptyHeatmap() -> [[Int]] {
        Array(repeating: Array(repeating: 0, count: 24), count: 7)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func argMax(_ values: [Int]) -> Int {
        var bestIndex = -1
        var best = -1
        for (index, value) in values.enumerated() where value > best {
            best = value
            bestIndex = index
        }
        return bestIndex
    }

    /// Mirrors ccgauge `computeStreaks`: longest consecutive local days with
    /// activity; current streak walks backward from the most recent active day
    /// when that day is today or yesterday.
    static func computeStreaks(
        dayKeys: Set<String>,
        windowDays: Int,
        calendar: Calendar,
        now: Date
    ) -> (current: Int, longest: Int) {
        guard !dayKeys.isEmpty else { return (0, 0) }

        let days = dayKeys.compactMap { parseDayKey($0, calendar: calendar) }.sorted()
        guard !days.isEmpty else { return (0, 0) }

        var longest = 1
        var run = 1
        for index in 1..<days.count {
            let previous = days[index - 1]
            let current = days[index]
            if let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(next, inSameDayAs: current) {
                run += 1
                if run > longest { longest = run }
            } else {
                run = 1
            }
        }

        let today = calendar.startOfDay(for: now)
        let lastDay = days[days.count - 1]
        guard let gap = calendar.dateComponents([.day], from: lastDay, to: today).day, gap <= 1 else {
            return (0, longest)
        }

        let daySet = Set(days.map { dayKey(for: $0, calendar: calendar) })
        var cursor = lastDay
        var current = 0
        var scanned = 0
        while scanned < windowDays, daySet.contains(dayKey(for: cursor, calendar: calendar)) {
            current += 1
            scanned += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (current, longest)
    }

    private static func parseDayKey(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
    }
}
