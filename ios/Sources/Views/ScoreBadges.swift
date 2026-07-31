import SwiftUI

/// Colour + label vocabulary for the scoring engine's outputs, plus a compact
/// crypto formatter. Shared by the Targets list and Target Detail.
enum ScoreStyle {
    static func bandColor(_ band: ScoreBand) -> Color {
        switch band {
        case .critical: return Theme.danger
        case .high:     return Theme.orange
        case .medium:   return Theme.warning
        case .low:      return Theme.textFaint
        }
    }

    static func activityColor(_ a: ActivityState) -> Color {
        switch a {
        case .active:     return Theme.success
        case .semiActive: return Theme.info
        case .review:     return Theme.warning
        case .inactive:   return Theme.textFaint
        }
    }

    static func recommendationColor(_ r: RecommendedAction) -> Color {
        switch r {
        case .siphon: return Theme.crypto
        case .spam:   return Theme.orange
        case .virus:  return Theme.purple
        case .skip:   return Theme.textFaint
        }
    }

    static func tierColor(_ tier: ValueTier?) -> Color {
        switch tier {
        case .none:         return Theme.textFaint
        case .low:          return Theme.textSecondary
        case .medium:       return Theme.info
        case .high:         return Theme.accent
        case .ultra:        return Theme.purple
        case .godly:        return Theme.crypto
        }
    }

    static func trendColor(_ d: TrendDirection) -> Color {
        switch d {
        case .rising:    return Theme.success
        case .declining: return Theme.danger
        case .steady:    return Theme.textSecondary
        case .unknown:   return Theme.textFaint
        }
    }

    static func trendIcon(_ d: TrendDirection) -> String {
        switch d {
        case .rising:    return "arrow.up.right"
        case .declining: return "arrow.down.right"
        case .steady:    return "arrow.right"
        case .unknown:   return "questionmark"
        }
    }
}

/// Compact crypto amount: 1.2K / 3.4M / 5.1B, else the trimmed number. "—" for nil.
enum CryptoFormat {
    static func compact(_ v: Double?) -> String {
        guard let v, v != 0 else { return v == nil ? "—" : "0" }
        let abs = Swift.abs(v)
        switch abs {
        case 1_000_000_000...: return trim(v / 1_000_000_000) + "B"
        case 1_000_000...:     return trim(v / 1_000_000) + "M"
        case 1_000...:         return trim(v / 1_000) + "K"
        default:               return trim(v)
        }
    }

    static func trim(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.1f", v)
    }
}

/// Circular score chip: the 0–100 number ringed in its band colour.
struct ScoreBadge: View {
    let score: Double
    let band: ScoreBand
    var size: CGFloat = 46

    var body: some View {
        let color = ScoreStyle.bandColor(band)
        Text(CryptoFormat.trim(score))
            .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
            .foregroundColor(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.14)))
            .overlay(Circle().stroke(color.opacity(0.55), lineWidth: 2))
    }
}
