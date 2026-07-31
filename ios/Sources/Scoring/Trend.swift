import Foundation

/// Where a target's haul is heading. Port of `trend.ts` YieldTrend.
enum TrendDirection: String, Sendable {
    case rising = "RISING"
    case steady = "STEADY"
    case declining = "DECLINING"
    case unknown = "UNKNOWN"
}

struct YieldTrend: Equatable, Sendable {
    var direction: TrendDirection
    /// -100…100 percentage change of the recent window vs the baseline, or nil.
    var percent: Int?

    static let unknown = YieldTrend(direction: .unknown, percent: nil)
}

/// Compares the average of the most-recent hauls against an older baseline.
/// Port of `trend.ts`.
enum Trend {
    static let recentWindow = 5
    static let baselineWindow = 10
    static let minimumSample = 4
    static let directionThreshold = 10.0

    /// `events` are individual extractions; only `.amount` matters here.
    static func compute(_ events: [CryptoEvent]) -> YieldTrend {
        guard events.count >= minimumSample else { return .unknown }

        // Newest first.
        let sorted = events.sorted { $0.date > $1.date }
        let recent = Array(sorted.prefix(recentWindow))
        let baseline = Array(sorted.dropFirst(recentWindow).prefix(baselineWindow))
        guard !baseline.isEmpty else { return .unknown }

        let recentAvg = average(recent)
        let baselineAvg = average(baseline)

        let raw = ((recentAvg - baselineAvg) / max(baselineAvg, 1)) * 100
        let percent = Int(min(100, max(-100, raw)).rounded())

        let direction: TrendDirection
        if Double(percent) >= directionThreshold { direction = .rising }
        else if Double(percent) <= -directionThreshold { direction = .declining }
        else { direction = .steady }

        return YieldTrend(direction: direction, percent: percent)
    }

    private static func average(_ events: [CryptoEvent]) -> Double {
        guard !events.isEmpty else { return 0 }
        let sum = events.reduce(0.0) { $0 + $1.amount }
        return sum / Double(events.count)
    }
}
