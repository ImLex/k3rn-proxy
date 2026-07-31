import SwiftUI

/// Personal tracker: the targets this member has opened in-game, synced from
/// their private capture inbox + theft history, scored by the potential engine,
/// and ranked highest-value first.
struct TrackerView: View {
    let actor: Actor
    @EnvironmentObject private var store: TrackerStore
    @AppStorage("user_level") private var userLevel = 0

    /// Players paired with their live assessment, ranked by score descending.
    private var ranked: [(player: TrackedPlayer, assessment: TargetAssessment)] {
        store.players
            .map { ($0, store.assessment(for: $0, userLevel: userLevel)) }
            .sorted { $0.1.score > $1.1.score }
    }

    var body: some View {
        NavigationView {
            Group {
                if store.players.isEmpty {
                    ScrollView {
                        if let e = store.lastError { ErrorBanner(message: e).padding(.horizontal) }
                        EmptyState(
                            systemImage: "scope",
                            title: "No tracked targets",
                            message: "Open a target in-game with the VPN on — it shows up here privately."
                        )
                    }
                    .refreshable { await store.refresh() }
                } else {
                    List {
                        if let e = store.lastError {
                            ErrorBanner(message: e)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                        ForEach(ranked, id: \.player.id) { item in
                            NavigationLink {
                                TrackedPlayerDetailView(trackedID: item.player.id, actor: actor)
                            } label: { row(item.player, item.assessment) }
                            .listRowBackground(Theme.surface)
                        }
                    }
                    .listStyle(.plain)
                    .hideScrollBackground()
                    .refreshable { await store.refresh() }
                }
            }
            .background(Theme.background)
            .navigationTitle("Targets")
        }
        .task { await store.refresh() }
    }

    private func row(_ p: TrackedPlayer, _ a: TargetAssessment) -> some View {
        HStack(spacing: Space.md) {
            ScoreBadge(score: a.score, band: a.band)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Space.sm) {
                    Text(p.username)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let lvl = p.level {
                        Text("Lv \(lvl)").font(.mono(12)).foregroundStyle(Theme.textSecondary)
                    }
                    if p.isUploaded {
                        Image(systemName: "checkmark.icloud")
                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                }
                HStack(spacing: Space.xs) {
                    TagPill(label: a.activity.label, color: ScoreStyle.activityColor(a.activity))
                    TagPill(label: a.recommendation.label,
                            color: ScoreStyle.recommendationColor(a.recommendation))
                    if a.trend.direction != .unknown {
                        Image(systemName: ScoreStyle.trendIcon(a.trend.direction))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ScoreStyle.trendColor(a.trend.direction))
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(CryptoFormat.compact(p.cryptoHot))
                    .font(.mono(15, weight: .semibold)).foregroundStyle(Theme.crypto)
                Text("held").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.vertical, 4)
    }
}
