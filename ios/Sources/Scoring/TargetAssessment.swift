import Foundation

/// The full scoring readout for one target, assembled from its capture row and
/// theft history. Everything the Targets list and Target Detail screens display.
struct TargetAssessment: Sendable {
    let totals: CryptoTotals
    let activity: ActivityState
    let breakdown: ScoreBreakdown
    /// Tier of the crypto currently held (what a steal is worth right now).
    let currentTier: ValueTier?
    /// Tier of the target's proven refill rate (what it's worth long-term).
    let yieldTier: ValueTier?
    let trend: YieldTrend
    let recommendation: RecommendedAction

    var score: Double { breakdown.score }
    var band: ScoreBand { breakdown.band }
}

/// Turns a `TrackedPlayer` + its `CryptoEvent` history into a `TargetAssessment`.
/// Pure — no I/O — so the list can score every target cheaply on each render.
enum TargetAssessor {
    static func assess(
        player: TrackedPlayer,
        events: [CryptoEvent],
        userLevel: Int,
        now: Date = Date()
    ) -> TargetAssessment {
        let totals = CryptoTotals.from(events, now: now)
        let activity = deriveActivity(totals: totals, now: now)
        let level = player.level ?? 0
        let cryptoHeld = player.cryptoHot ?? 0

        let input = ScoreInput(
            level: level,
            cryptoHeld: cryptoHeld,
            totals: totals,
            activity: activity,
            firewall: player.firewall,
            software: player.software,
            device: nil,                       // device tier isn't captured on iOS yet
            attackCount: totals.eventCount,
            dateAdded: Formatting.date(from: player.capturedAt)
        )

        let breakdown = PotentialScore.explain(input, now: now)
        return TargetAssessment(
            totals: totals,
            activity: activity,
            breakdown: breakdown,
            currentTier: ValueScale.tierFor(level: level, crypto: cryptoHeld),
            yieldTier: ValueScale.yieldTierFor(level: level, ratePerActiveDay: totals.averagePerActiveDay),
            trend: Trend.compute(events),
            recommendation: Recommendation.recommend(input: input, score: breakdown.score, userLevel: userLevel)
        )
    }

    /// iOS has no accessibility live-ness signal, so activity is derived from theft
    /// recency: the more recently we've pulled crypto, the more active the target.
    static func deriveActivity(totals: CryptoTotals, now: Date) -> ActivityState {
        guard let last = totals.lastExtraction else { return .review }
        let age = now.timeIntervalSince(last)
        switch age {
        case ..<(2 * 86_400):  return .active
        case ..<(7 * 86_400):  return .semiActive
        case ..<(30 * 86_400): return .review
        default:               return .inactive
        }
    }
}
