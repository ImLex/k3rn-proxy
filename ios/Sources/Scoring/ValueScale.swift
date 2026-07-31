import Foundation

/// Crypto-value tiers, ordered low → high. Port of `valueScale.ts` VALUE_TIERS.
enum ValueTier: String, CaseIterable, Comparable, Sendable {
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case ultra = "ULTRA"
    case godly = "GODLY"

    /// Crypto anchor at `ValueScale.anchorLevel` (level 30).
    var anchorValue: Double {
        switch self {
        case .low:    return 250
        case .medium: return 500
        case .high:   return 1000
        case .ultra:  return 1500
        case .godly:  return 2500
        }
    }

    var label: String { rawValue.capitalized }

    static func < (l: ValueTier, r: ValueTier) -> Bool {
        allCases.firstIndex(of: l)! < allCases.firstIndex(of: r)!
    }
}

/// Level-scaled crypto tiers. Thresholds scale linearly with level from a level-30
/// anchor, floor-rounded. Port of `valueScale.ts`.
enum ValueScale {
    static let anchorLevel = 30.0

    /// Crypto needed at `level` to reach `tier`. `floor((anchor/30) * max(0, level))`.
    static func threshold(level: Int, tier: ValueTier) -> Double {
        let scaled = (tier.anchorValue / anchorLevel) * Double(max(0, level))
        return scaled.rounded(.down)
    }

    /// Highest tier whose threshold `crypto` clears at `level`, or nil if below LOW.
    /// Shared by current-value (crypto held) and yield (rate/active-day).
    static func tierFor(level: Int, crypto: Double) -> ValueTier? {
        for tier in ValueTier.allCases.reversed() {
            let t = threshold(level: level, tier: tier)
            if t > 0 && crypto >= t { return tier }
        }
        return nil
    }

    /// Yield tier — same math as `tierFor`, keyed on rate-per-active-day.
    static func yieldTierFor(level: Int, ratePerActiveDay: Double) -> ValueTier? {
        tierFor(level: level, crypto: ratePerActiveDay)
    }

    /// 0…1 fraction of the way to GODLY at `level`, clamped.
    static func tierProgress(level: Int, crypto: Double) -> Double {
        let godly = threshold(level: level, tier: .godly)
        guard godly > 0 else { return 0 }
        return min(1, max(0, crypto / godly))
    }
}
