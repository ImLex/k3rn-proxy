import Foundation

/// A target's live-ness. Ported from Android `db/types.ts` ACTIVITY_STATES.
/// On iOS this is derived from theft recency (no accessibility signal), so it
/// defaults to `.review` when nothing is known.
enum ActivityState: String, Codable, CaseIterable, Sendable {
    case active = "ACTIVE"
    case semiActive = "SEMI_ACTIVE"
    case review = "REVIEW"
    case inactive = "INACTIVE"

    var label: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

/// One crypto extraction from a target (a row of `target_crypto_events`).
struct CryptoEvent: Hashable, Codable, Sendable {
    let amount: Double
    let date: Date
}

/// Crypto figures derived from a target's event history. Never stored — computed
/// on read, mirroring Android `CryptoTotals` (`db/repo/logs.ts`).
struct CryptoTotals: Equatable, Sendable {
    var extractedTotal: Double = 0
    var extractedToday: Double = 0
    var extracted7Days: Double = 0
    var extracted30Days: Double = 0
    var eventCount: Int = 0
    var firstExtraction: Date?
    var lastExtraction: Date?
    /// Total divided by the number of distinct days that had an extraction, so
    /// idle stretches don't dilute the average.
    var averagePerActiveDay: Double = 0

    static let empty = CryptoTotals()

    /// Port of `getCryptoTotals` + `buildTotals`. Windows: today = local midnight,
    /// 7/30-day = rolling; active-days bucketed by UTC day (date / 86400s).
    static func from(_ events: [CryptoEvent], now: Date = Date()) -> CryptoTotals {
        guard !events.isEmpty else { return .empty }
        let startToday = Calendar.current.startOfDay(for: now)
        let d7 = now.addingTimeInterval(-7 * 86_400)
        let d30 = now.addingTimeInterval(-30 * 86_400)

        var total = 0.0, today = 0.0, week = 0.0, month = 0.0
        var days = Set<Int>()
        var first = events[0].date
        var last = events[0].date
        for e in events {
            total += e.amount
            if e.date >= startToday { today += e.amount }
            if e.date >= d7 { week += e.amount }
            if e.date >= d30 { month += e.amount }
            days.insert(Int(e.date.timeIntervalSince1970 / 86_400))
            if e.date < first { first = e.date }
            if e.date > last { last = e.date }
        }
        let activeDays = Double(max(1, days.count))
        return CryptoTotals(
            extractedTotal: total,
            extractedToday: today,
            extracted7Days: week,
            extracted30Days: month,
            eventCount: events.count,
            firstExtraction: first,
            lastExtraction: last,
            averagePerActiveDay: total / activeDays
        )
    }
}
