import Foundation

/// Everything the scoring engine needs about one target. Assembled from a
/// `TrackedPlayer` capture row + its derived `CryptoTotals`.
struct ScoreInput: Sendable {
    var level: Int
    /// Stealable crypto currently held (captures.crypto_hot).
    var cryptoHeld: Double
    var totals: CryptoTotals
    var activity: ActivityState
    /// Firewall level from the capture row — the primary defence signal on iOS.
    var firewall: Int?
    var software: [CapturedSoftware]
    var device: String?
    /// Times the member has attacked this target (0 if unknown). Feeds the
    /// unproven-target nudge alongside `totals.eventCount`.
    var attackCount: Int = 0
    /// When the target was first captured — freshness for the unproven nudge.
    var dateAdded: Date?
}

enum ScoreBand: String, Sendable {
    case critical, high, medium, low

    var label: String { rawValue.capitalized }
}

/// One weighted contribution to the 0–100 score, for the "why this score" breakdown.
struct ScoreComponent: Identifiable, Sendable {
    let key: String
    let label: String
    let value: Double   // 0…1 normalised
    let weight: Double
    var weighted: Double { value * weight }
    var id: String { key }
}

struct ScoreBreakdown: Sendable {
    let score: Double          // 0…100, one decimal
    let band: ScoreBand
    let components: [ScoreComponent]
}

/// Weighted 0–100 potential score. Port of `potentialScore.ts`, adapted to the
/// iOS capture model (DEFENSE category + firewall column, no software owner field).
enum PotentialScore {
    private static let day = 86_400.0

    private enum Weight {
        static let currentValue = 0.20
        static let refillSpeed = 0.25
        static let provenYield = 0.20
        static let activity = 0.12
        static let defences = 0.08
        static let device = 0.15
    }

    /// `v/(v+mid)` diminishing-returns curve; 0 when either input is non-positive.
    private static func saturate(_ v: Double, _ mid: Double) -> Double {
        guard v > 0, mid > 0 else { return 0 }
        return v / (v + mid)
    }

    private static func activityScore(_ a: ActivityState) -> Double {
        switch a {
        case .active:     return 1.0
        case .semiActive: return 0.7
        case .review:     return 0.5
        case .inactive:   return 0.2
        }
    }

    /// Weak defences → high score (soft target). Folds firewall + any defensive
    /// software, normalised against the target's level.
    private static func defenceValue(_ input: ScoreInput) -> Double {
        let softwareMax = input.software
            .filter { isDefensive($0.category) }
            .map(\.level)
            .max() ?? 0
        let highestDefence = Double(max(input.firewall ?? 0, softwareMax))

        let ratio: Double
        if input.level > 0 {
            ratio = min(1, highestDefence / Double(input.level))
        } else {
            ratio = highestDefence > 0 ? 1 : 0
        }
        return 1 - ratio
    }

    private static func isDefensive(_ category: String?) -> Bool {
        guard let c = category?.uppercased() else { return false }
        return c == "DEFENSE" || c == "DEFENSIVE"
    }

    static func explain(_ input: ScoreInput, now: Date = Date()) -> ScoreBreakdown {
        let godly = ValueScale.threshold(level: input.level, tier: .godly)

        let currentValue = godly > 0 ? min(1, input.cryptoHeld / godly) : 0
        let refillReference = max(godly * 0.5, 100)
        let refillSpeed = saturate(input.totals.averagePerActiveDay, refillReference)
        let provenYield = saturate(input.totals.extractedTotal, max(godly, 500))
        let activity = activityScore(input.activity)
        let defences = defenceValue(input)
        let device = Devices.strength(input.device)

        let components = [
            ScoreComponent(key: "currentValue", label: "Current value",
                           value: currentValue, weight: Weight.currentValue),
            ScoreComponent(key: "refillSpeed", label: "Refill speed",
                           value: refillSpeed, weight: Weight.refillSpeed),
            ScoreComponent(key: "provenYield", label: "Proven yield",
                           value: provenYield, weight: Weight.provenYield),
            ScoreComponent(key: "activity", label: "Activity",
                           value: activity, weight: Weight.activity),
            ScoreComponent(key: "defences", label: "Soft defences",
                           value: defences, weight: Weight.defences),
            ScoreComponent(key: "device", label: "Device tier",
                           value: device, weight: Weight.device),
        ]

        var score = components.reduce(0) { $0 + $1.weighted } * 100

        // Unproven-target nudge toward 50, fading over 14 days from capture.
        let isUnproven = input.totals.eventCount == 0 && input.attackCount == 0
        if isUnproven, let added = input.dateAdded {
            let ageDays = max(0, now.timeIntervalSince(added) / day)
            let freshness = max(0, 1 - ageDays / 14)
            score += (50 - score) * 0.35 * freshness
        }

        score = (min(100, max(0, score)) * 10).rounded() / 10
        return ScoreBreakdown(score: score, band: band(score), components: components)
    }

    static func score(_ input: ScoreInput, now: Date = Date()) -> Double {
        explain(input, now: now).score
    }

    static func band(_ score: Double) -> ScoreBand {
        switch score {
        case 75...:  return .critical
        case 55...:  return .high
        case 35...:  return .medium
        default:     return .low
        }
    }
}
