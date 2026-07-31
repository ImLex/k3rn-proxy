import SwiftUI

/// Lightweight chart primitives hand-rolled for iOS 15 (Swift Charts is iOS 16+).
/// Ported from the Android companion's `ui/Charts.tsx` (DailyCryptoChart /
/// RankBar / BreakdownBar).

/// A row of vertical bars, one per day, height ∝ value. Empty days render as a
/// faint baseline tick so the timeline stays legible.
struct MiniBarChart: View {
    let values: [Double]
    var color: Color = Theme.crypto
    var height: CGFloat = 64

    var body: some View {
        let maxV = max(values.max() ?? 0, 1)
        GeometryReader { geo in
            let count = max(values.count, 1)
            let gap: CGFloat = 3
            let barW = max((geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    let h = v <= 0 ? 2 : max(geo.size.height * CGFloat(v / maxV), 3)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(v <= 0 ? Theme.border : color)
                        .frame(width: barW, height: h)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: height)
    }
}

/// Horizontal magnitude bar (value / max) used for "biggest earners".
struct RankBar: View {
    let value: Double
    let max: Double
    var color: Color = Theme.crypto

    var body: some View {
        GeometryReader { geo in
            let frac = max <= 0 ? 0 : min(CGFloat(value / max), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceHigh)
                Capsule().fill(color).frame(width: geo.size.width * frac)
            }
        }
        .frame(height: 6)
    }
}

/// A single proportional stacked bar of coloured segments (target activity mix).
struct BreakdownBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let value: Int
        let color: Color
    }
    let segments: [Segment]

    var body: some View {
        let total = Swift.max(segments.reduce(0) { $0 + $1.value }, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments.filter { $0.value > 0 }) { seg in
                    seg.color
                        .frame(width: geo.size.width * CGFloat(seg.value) / CGFloat(total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}
