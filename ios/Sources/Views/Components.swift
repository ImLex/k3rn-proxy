import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Monospaced IP with tap-to-copy (haptic + brief "Copied" flash), guide §7.
struct CopyableIP: View {
    let ip: String?
    var font: Font = .mono(15)

    @State private var copied = false

    var body: some View {
        if let ip, !ip.isEmpty {
            Button {
                Formatting.copyToClipboard(ip)
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    withAnimation { copied = false }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(ip).font(font).foregroundStyle(Theme.textPrimary)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? Theme.accent : Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            Text("—").font(font).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Dashboard stat card.
struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

struct RankBadge: View {
    let rank: CrewRank

    var body: some View {
        if let icon = Theme.rankIcon(rank) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.rankColor(rank))
        }
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyState: View {
    let systemImage: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(Theme.textSecondary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let message {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Neutral, dismissable one-line notice — used for e.g. "Uploaded 3" toast
/// after a multi-select action.
struct InfoBanner: View {
    let message: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Small labelled key/value row used on detail screens.
struct DetailRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            value
        }
        .padding(.vertical, 4)
    }
}
