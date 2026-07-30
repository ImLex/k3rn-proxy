import SwiftUI

// Components mirrored from the Android app's `src/ui/components.tsx`.
// iOS 15 compatible.

// MARK: - Button

enum KButtonVariant {
    case primary, secondary, ghost, danger

    var bg: Color {
        switch self {
        case .primary: return Theme.accent
        case .secondary: return Theme.surfaceHigh
        case .ghost, .danger: return .clear
        }
    }
    var fg: Color {
        switch self {
        case .primary: return Theme.accentText
        case .secondary: return Theme.textPrimary
        case .ghost: return Theme.textSecondary
        case .danger: return Theme.danger
        }
    }
    var border: Color {
        switch self {
        case .primary: return .clear
        case .secondary, .ghost: return Theme.border
        case .danger: return Theme.danger
        }
    }
}

struct KButton: View {
    let label: String
    var variant: KButtonVariant = .primary
    var systemImage: String? = nil
    var loading: Bool = false
    var disabled: Bool = false
    var full: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                if loading {
                    ProgressView().tint(variant.fg)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(label).font(.bodyStrong)
            }
            .frame(maxWidth: full ? .infinity : nil, minHeight: 46)
            .padding(.horizontal, Space.lg)
            .foregroundColor(variant.fg)
            .background(variant.bg)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(variant.border, lineWidth: 1)
            )
            .opacity(disabled || loading ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled || loading)
    }
}

// MARK: - Chip

struct Chip: View {
    let label: String
    var color: Color = Theme.textSecondary
    var selected: Bool = false
    var small: Bool = false

    var body: some View {
        Text(label)
            .font(small ? .caption : .labelM)
            .foregroundColor(selected ? color : Theme.textSecondary)
            .padding(.vertical, small ? 2 : 5)
            .padding(.horizontal, small ? Space.sm : Space.md)
            .background(selected ? color.opacity(0.13) : Theme.surfaceHigh)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(selected ? color : Theme.border, lineWidth: 1)
            )
    }
}

// MARK: - Tag pill (recommendation / semantic label)

struct TagPill: View {
    let label: String
    var color: Color = Theme.accent

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(color)
            .padding(.vertical, 3)
            .padding(.horizontal, Space.sm)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

// MARK: - StatTile

struct StatTile: View {
    let label: String
    let value: String
    var color: Color = Theme.textPrimary
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption)
                .foregroundColor(Theme.textFaint)
            Text(value)
                .font(.titleXL)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, Space.xs)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(Theme.textFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: Space.md)
    }
}

// MARK: - ProgressBar

struct ProgressBar: View {
    let progress: Double
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceHigh)
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: height)
    }
}

// MARK: - SegmentedControl

struct SegmentedControl<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSel = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.labelM)
                        .foregroundColor(isSel ? Theme.accentText : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.sm)
                        .background(isSel ? Theme.accent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.surfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

// MARK: - Section (titled group)

struct SectionCard<Content: View>: View {
    let title: String
    var action: (() -> Void)? = nil
    var actionLabel: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                if let action, let actionLabel {
                    Button(actionLabel, action: action)
                        .font(.labelM)
                        .foregroundColor(Theme.accent)
                }
            }
            content()
        }
    }
}
