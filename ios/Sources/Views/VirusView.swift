import SwiftUI

/// Virus tab: what to do with each tracked target (Siphon / Spam / Virus / Skip).
/// v1 lists tracked targets with the stats that drive the decision; the full
/// Android scoring engine (activity + crypto-per-active-day) lands in a later pass.
struct VirusView: View {
    let actor: Actor
    @EnvironmentObject private var store: TrackerStore

    private var targets: [TrackedPlayer] {
        store.players.sorted { ($0.level ?? 0) > ($1.level ?? 0) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if let e = store.lastError { ErrorBanner(message: e) }

                    banner

                    if targets.isEmpty {
                        EmptyState(
                            systemImage: "ladybug",
                            title: "No targets to assess",
                            message: "Open targets in-game with the VPN on — they show up here to plan spam and siphon runs."
                        )
                    } else {
                        ForEach(targets) { p in
                            NavigationLink {
                                TrackedPlayerDetailView(trackedID: p.id, actor: actor)
                            } label: { card(p) }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(Theme.background)
            .navigationTitle("Virus")
            .refreshable { await store.refresh() }
        }
        .task { await store.refresh() }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "info.circle")
                .foregroundColor(Theme.accent)
            Text("Full Siphon/Spam/Virus scoring is coming. For now, targets are ranked by level with the stats that drive the call.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: Space.md)
    }

    private func card(_ p: TrackedPlayer) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(p.username).font(.heading).foregroundColor(Theme.textPrimary)
                Spacer()
                TagPill(label: verdict(p).0, color: verdict(p).1)
            }
            HStack(spacing: Space.sm) {
                stat("LVL", p.level)
                stat("FW", p.firewall)
                stat("REP", p.reputation)
                if !p.software.isEmpty {
                    stat("SW", p.software.count)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func stat(_ label: String, _ value: Int?) -> some View {
        VStack(spacing: 1) {
            Text(value.map(String.init) ?? "—").font(.mono(15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.textFaint)
        }
        .frame(minWidth: 44)
    }

    // Preliminary heuristic placeholder until the full scoring engine ships.
    private func verdict(_ p: TrackedPlayer) -> (String, Color) {
        let rep = p.reputation ?? 0
        let fw = p.firewall ?? 0
        if rep >= 1000 { return ("Siphon", Theme.crypto) }
        if fw >= 8 { return ("Spam", Theme.orange) }
        return ("Virus", Theme.purple)
    }
}
