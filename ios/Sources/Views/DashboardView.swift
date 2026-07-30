import SwiftUI

struct DashboardView: View {
    let actor: Actor
    @EnvironmentObject private var nicknames: NicknameStore

    @State private var stats: DashboardStats?
    @State private var crewCount = 0
    @State private var activity: [AuditLog] = []
    @State private var recent: [Player] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showActivity = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatCard(title: "Players", value: "\(stats?.players ?? 0)",
                                 systemImage: "person.fill")
                        StatCard(title: "Known IPs", value: "\(stats?.knownIPs ?? 0)",
                                 systemImage: "network")
                        StatCard(title: "Crews", value: "\(crewCount)",
                                 systemImage: "person.3.fill")
                        StatCard(title: "Updated Today", value: "\(stats?.updatedToday ?? 0)",
                                 systemImage: "calendar")
                    }

                    activitySection
                    recentSection
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Dashboard")
            .refreshable { await load() }
            .task { if loading { await load() } }
            .sheet(isPresented: $showActivity) { ActivityView() }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Recent Activity")
                Button { showActivity = true } label: {
                    Text("See all").font(.labelM).foregroundColor(Theme.accent)
                }
            }
            if activity.isEmpty {
                EmptyState(systemImage: "clock", title: "No activity yet")
            } else {
                ForEach(activity) { log in
                    AuditRow(log: log, nicknames: nicknames)
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recently Updated")
            if recent.isEmpty {
                EmptyState(systemImage: "person.crop.circle.badge.questionmark",
                           title: "No players yet")
            } else {
                ForEach(recent) { player in
                    NavigationLink {
                        PlayerDetailView(playerID: player.id, actor: actor)
                    } label: {
                        PlayerRow(player: player)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            async let s = DashboardService.stats()
            async let c = DashboardService.crewCount()
            async let a = DashboardService.recentActivity()
            async let r = DashboardService.recentlyUpdated()
            stats = try await s
            crewCount = try await c
            activity = try await a
            recent = try await r
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
        loading = false
    }
}

/// Compact player list row reused across Dashboard/Search.
struct PlayerRow: View {
    let player: Player

    var body: some View {
        HStack(spacing: 10) {
            RankBadge(rank: player.rank)
            VStack(alignment: .leading, spacing: 3) {
                Text(player.username)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 8) {
                    if let crew = player.crew, !crew.isEmpty {
                        Text(crew).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    CopyableIP(ip: player.currentIP, font: .mono(12))
                }
            }
            Spacer()
            Text(Formatting.relativeTime(player.updatedAt))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }
}

struct AuditRow: View {
    let log: AuditLog
    let nicknames: NicknameStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(log.action)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(nicknames.nickname(forDiscordID: log.discordUserID,
                                        fallback: log.discordUsername))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text(Formatting.relativeTime(log.timestamp))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .cardStyle()
    }

    private var icon: String {
        switch log.action {
        case "player.create": return "plus.circle"
        case "player.update": return "pencil.circle"
        case "player.delete": return "trash.circle"
        case "player.restore": return "arrow.uturn.backward.circle"
        case "player.capture": return "dot.radiowaves.left.and.right"
        default: return "circle"
        }
    }
}
