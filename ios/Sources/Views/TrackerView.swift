import SwiftUI

/// Personal tracker: the targets this member has opened in-game, synced from
/// their private capture inbox and cached on device.
struct TrackerView: View {
    let actor: Actor
    @EnvironmentObject private var store: TrackerStore

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
                        ForEach(store.players) { p in
                            NavigationLink {
                                TrackedPlayerDetailView(trackedID: p.id, actor: actor)
                            } label: { row(p) }
                            .listRowBackground(Theme.surface)
                        }
                    }
                    .listStyle(.plain)
                    .hideScrollBackground()
                    .refreshable { await store.refresh() }
                }
            }
            .background(Theme.background)
            .navigationTitle("Tracker")
        }
        .task { await store.refresh() }
    }

    private func row(_ p: TrackedPlayer) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.username)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 8) {
                    if let c = p.crew, !c.isEmpty {
                        Text(c).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    if let lvl = p.level {
                        Text("Lv \(lvl)").font(.mono(12)).foregroundStyle(Theme.textSecondary)
                    }
                    if !p.software.isEmpty {
                        Text("\(p.software.count) sw")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Spacer()
            if p.isUploaded {
                Image(systemName: "checkmark.icloud")
                    .font(.system(size: 13)).foregroundStyle(Theme.accent)
            }
            Text(Formatting.relativeTime(p.capturedAt))
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
    }
}
