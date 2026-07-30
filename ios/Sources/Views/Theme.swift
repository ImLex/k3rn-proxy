import SwiftUI

/// Design tokens mirrored from the Android companion app (`src/ui/theme.ts`).
/// Nothing else should hard-code a colour. Dark-only.
enum Theme {
    // MARK: Backgrounds, back to front
    static let background = hex(0x0E1116)
    static let surface = hex(0x161B22)
    static let surfaceRaised = hex(0x1C232C)
    static let surfaceHigh = hex(0x232B36)
    static let border = hex(0x2A333F)
    static let borderStrong = hex(0x3A4553)

    // MARK: Text
    static let textPrimary = hex(0xE8EDF4)
    static let textSecondary = hex(0x9BA7B7)   // Android textMuted
    static let textFaint = hex(0x6B7889)
    static let textInverse = hex(0x0E1116)

    // MARK: Accent (single interactive colour)
    static let accent = hex(0x3ED2D0)
    static let accentMuted = hex(0x1F5C5E)
    static let accentText = hex(0x0E1116)

    // MARK: Semantic
    static let success = hex(0x42C08A)
    static let warning = hex(0xF5B841)
    static let danger = hex(0xE5484D)
    static let info = hex(0x4FA3E3)
    static let purple = hex(0xC77DFF)
    static let orange = hex(0xFF7A45)
    static let pink = hex(0xFF5C8A)
    static let crypto = hex(0xF5B841)

    // MARK: Crew ranks (kept for existing screens)
    static let leader = warning     // gold
    static let officer = info       // blue

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

    static func hex(_ value: UInt32, alpha: Double = 1) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Spacing scale (Android `spacing`).
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner-radius scale (Android `radius`).
enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let pill: CGFloat = 999
}

extension Font {
    // Type scale mirrored from Android `typography`.
    static let display = Font.system(size: 32, weight: .bold)
    static let titleXL = Font.system(size: 22, weight: .bold)
    static let heading = Font.system(size: 17, weight: .semibold)
    static let bodyM = Font.system(size: 15, weight: .regular)
    static let bodyStrong = Font.system(size: 15, weight: .semibold)
    static let labelM = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12, weight: .regular)

    /// Monospaced treatment for IPs and numbers.
    static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// Standard 16px bordered card on `surface` (Android `Card`).
    func cardStyle(padding: CGFloat = Space.lg) -> some View {
        self
            .padding(padding)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }

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
