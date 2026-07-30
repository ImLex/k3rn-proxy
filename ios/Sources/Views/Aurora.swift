import SwiftUI

/// Animated "Aurora" glow background mirrored from the Android app: three large
/// blurred colour blobs that slowly drift and breathe behind the content.
/// iOS 15 compatible (plain repeating animations, no TimelineView).
struct AuroraBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Theme.background

            blob(Theme.accent, size: 340, opacity: 0.20)
                .offset(x: animate ? -90 : -60, y: animate ? -190 : -230)
                .scaleEffect(animate ? 1.15 : 0.90)
                .animation(.easeInOut(duration: 12).repeatForever(autoreverses: true), value: animate)

            blob(Theme.info, size: 300, opacity: 0.16)
                .offset(x: animate ? 120 : 80, y: animate ? -30 : 30)
                .scaleEffect(animate ? 0.95 : 1.20)
                .animation(.easeInOut(duration: 16).repeatForever(autoreverses: true), value: animate)

            blob(Theme.purple, size: 380, opacity: 0.14)
                .offset(x: animate ? -40 : 40, y: animate ? 270 : 320)
                .scaleEffect(animate ? 1.20 : 0.95)
                .animation(.easeInOut(duration: 20).repeatForever(autoreverses: true), value: animate)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { animate = true }
    }

    private func blob(_ color: Color, size: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(opacity)
            .blur(radius: 80)
    }
}

/// Standard screen scaffold: Aurora background + optional scroll. Mirrors the
/// Android `Screen` wrapper. Use inside a NavigationView.
struct Screen<Content: View>: View {
    var scroll: Bool = true
    var spacing: CGFloat = Space.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            AuroraBackground()
            if scroll {
                ScrollView {
                    VStack(alignment: .leading, spacing: spacing) {
                        content()
                    }
                    .padding(Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: spacing) {
                    content()
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}
