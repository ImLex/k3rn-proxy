import SwiftUI

/// Dark-only palette matching the web dashboard (guide §8): near-black green
/// tint background (#101512), green accent, amber Leader / blue Officer.
enum Theme {
    static let background = Color(red: 0.063, green: 0.082, blue: 0.071)   // #101512
    static let surface = Color(red: 0.098, green: 0.125, blue: 0.110)      // slightly lighter card
    static let surfaceHigh = Color(red: 0.137, green: 0.169, blue: 0.149)
    static let accent = Color(red: 0.290, green: 0.902, blue: 0.545)       // AccentColor
    static let textPrimary = Color(red: 0.90, green: 0.94, blue: 0.91)
    static let textSecondary = Color(red: 0.62, green: 0.68, blue: 0.64)
    static let border = Color.white.opacity(0.08)

    static let leader = Color(red: 0.98, green: 0.75, blue: 0.24)   // amber/gold
    static let officer = Color(red: 0.45, green: 0.72, blue: 0.98)  // light blue

    static func rankColor(_ rank: CrewRank) -> Color {
        switch rank {
        case .leader: return leader
        case .officer: return officer
        case .member: return textSecondary
        }
    }

    static func rankIcon(_ rank: CrewRank) -> String? {
        switch rank {
        case .leader: return "crown.fill"
        case .officer: return "star.fill"
        case .member: return nil
        }
    }
}

extension View {
    /// Standard card container used across screens.
    func cardStyle() -> some View {
        self
            .padding(14)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

extension Font {
    /// Monospaced treatment for IPs and numbers (guide §8).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// Hide a List/ScrollView's system background so Theme.background shows.
    /// iOS 16+ uses the native modifier; on iOS 15 the clear List background is
    /// set globally via UITableView.appearance() in the app entry point.
    @ViewBuilder func hideScrollBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
