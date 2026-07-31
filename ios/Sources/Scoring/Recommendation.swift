import Foundation

/// What to do with a target. Port of `recommendation.ts` RecommendedAction.
enum RecommendedAction: String, Sendable {
    case siphon = "SIPHON"
    case spam = "SPAM"
    case virus = "VIRUS"
    case skip = "SKIP"

    var label: String { rawValue.capitalized }
}

/// First-match rule engine (order is deliberate). Port of `recommendation.ts`.
enum Recommendation {
    private static let richTiers: Set<ValueTier> = [.high, .ultra, .godly]
    private static let spamGapBelow = -9
    private static let spamGapAbove = 10
    private static let virusScore = 35.0

    /// `score` is the target's potential score; `userLevel` comes from Settings
    /// (0 = unknown, disables the spam-gap rule).
    static func recommend(input: ScoreInput, score: Double, userLevel: Int) -> RecommendedAction {
        let yieldTier = ValueScale.yieldTierFor(
            level: input.level,
            ratePerActiveDay: input.totals.averagePerActiveDay
        )
        let rich = yieldTier.map { richTiers.contains($0) } ?? false

        let levelDelta = input.level - userLevel
        let spamGap = userLevel > 0 && (levelDelta <= spamGapBelow || levelDelta >= spamGapAbove)

        if rich && (input.activity == .active || input.activity == .semiActive) {
            return .siphon
        }
        if !rich && spamGap {
            return .spam
        }
        if score >= virusScore {
            return .virus
        }
        return .skip
    }
}
