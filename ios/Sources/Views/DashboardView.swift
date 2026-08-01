import SwiftUI

/// Personal home screen, mirroring the Android companion's dashboard: which game
/// account is active, crypto earned over time, best targets by score, biggest
/// earners, the activity mix, and database counts. All derived from the private
/// tracker (`captures` + theft history), not the shared crew DB.
struct DashboardView: View {
    let actor: Actor?
    @EnvironmentObject private var store: TrackerStore
    @AppStorage("user_level") private var userLevel = 0
    @AppStorage("active_game_pid") private var activePID = ""

    // MARK: Derived rollups

    /// The account the switcher currently points at (defaults to newest capture).
    private var own: OwnProfile? {
        store.ownAccounts.first { $0.id == activePID } ?? store.ownAccounts.first
    }
    private var effectiveLevel: Int { own?.level ?? userLevel }

    private var assessments: [(player: TrackedPlayer, a: TargetAssessment)] {
        store.players.map { (player: $0, a: store.assessment(for: $0, userLevel: effectiveLevel)) }
    }
    private var allEvents: [CryptoEvent] { Array(store.eventsByPlayer.values.joined()) }
    private var totals: CryptoTotals { CryptoTotals.from(allEvents) }

    private var bestTargets: [(player: TrackedPlayer, a: TargetAssessment)] {
        Array(assessments.sorted { $0.a.score > $1.a.score }.prefix(5))
    }
    private var topEarners: [(player: TrackedPlayer, total: Double)] {
        assessments
            .map { (player: $0.player, total: $0.a.totals.extractedTotal) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
            .prefix(5).map { $0 }
    }
    private var activityCounts: [ActivityState: Int] {
        Dictionary(grouping: assessments, by: { $0.a.activity }).mapValues { $0.count }
    }
    /// Crypto taken per day over the last 14 days, oldest → newest.
    private var dailyValues: [Double] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var buckets = [Double](repeating: 0, count: 14)
        for e in allEvents {
            let day = cal.startOfDay(for: e.date)
            let diff = cal.dateComponents([.day], from: day, to: today).day ?? 99
            if diff >= 0 && diff < 14 { buckets[13 - diff] += e.amount }
        }
        return buckets
    }
    private var lastCaptureRelative: String {
        let dates = store.players.compactMap { Formatting.date(from: $0.capturedAt) }
        return Formatting.relativeTime(from: dates.max())
    }
    private var ownSubtitle: String {
        guard let lvl = own?.level else { return "Open your own profile in-game to sync" }
        if let rep = own?.reputation { return "Level \(lvl) · \(rep) rep" }
        return "Level \(lvl)"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if let e = store.lastError { ErrorBanner(message: e) }
                    accountHeader
                    if store.players.isEmpty {
                        EmptyState(
                            systemImage: "square.grid.2x2",
                            title: "Nothing tracked yet",
                            message: "Open a target in-game with the VPN on — captures show up here automatically."
                        )
                    } else {
                        cryptoEarned
                        if !bestTargets.isEmpty { bestTargetsSection }
                        if !topEarners.isEmpty { biggestEarners }
                        targetActivity
                        database
                    }
                }
                .padding()
                .padding(.bottom, Space.xxl)
            }
            .background(Theme.background)
            .navigationTitle("Dashboard")
            .refreshable { await reload() }
            .task { await reload() }
        }
    }

    /// Only hit the network when signed in; offline we show the local cache.
    private func reload() async { if actor != nil { await store.refresh() } }

    // MARK: Sections

    /// Which HackEx account is active. A tap switches between accounts when the
    /// member has logged in on more than one (mirrors the Android switcher).
    private var accountHeader: some View {
        Group {
            if store.ownAccounts.count > 1 {
                Menu {
                    ForEach(store.ownAccounts) { acc in
                        Button {
                            activePID = acc.id
                        } label: {
                            Label(acc.username ?? "Account",
                                  systemImage: acc.id == (own?.id ?? "") ? "checkmark" : "person")
                        }
                    }
                } label: { accountHeaderContent(switchable: true) }
            } else {
                accountHeaderContent(switchable: false)
            }
        }
    }

    private func accountHeaderContent(switchable: Bool) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 22)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.xs) {
                    Text(own?.username ?? "Account not synced yet")
                        .font(.bodyStrong).foregroundStyle(Theme.textPrimary)
                    if switchable {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }
                }
                Text(ownSubtitle)
                    .font(.caption).foregroundStyle(Theme.textFaint)
            }
            Spacer()
            if let hot = own?.cryptoHot {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(CryptoFormat.compact(hot))
                        .font(.mono(15, weight: .semibold)).foregroundStyle(Theme.crypto)
                    Text("held").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    private var cryptoEarned: some View {
        DashSection(
            title: "Crypto earned",
            subtitle: "\(totals.eventCount) \(totals.eventCount == 1 ? "extraction" : "extractions") recorded"
        ) {
            HStack(spacing: Space.sm) {
                MetricTile(label: "Today", value: CryptoFormat.compact(totals.extractedToday), color: Theme.crypto)
                MetricTile(label: "7 days", value: CryptoFormat.compact(totals.extracted7Days))
                MetricTile(label: "All time", value: CryptoFormat.compact(totals.extractedTotal))
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                MiniBarChart(values: dailyValues)
                if totals.eventCount > 0 {
                    Divider().background(Theme.border)
                    HStack(spacing: Space.lg) {
                        Text("Avg \(CryptoFormat.compact(totals.averagePerActiveDay))/active day")
                        Text("Last \(Formatting.relativeTime(from: totals.lastExtraction))")
                    }
                    .font(.caption).foregroundStyle(Theme.textFaint)
                }
            }
            .cardStyle()
        }
    }

    private var bestTargetsSection: some View {
        DashSection(title: "Best targets", subtitle: "Ranked by potential score") {
            VStack(spacing: 0) {
                ForEach(bestTargets, id: \.player.id) { item in
                    if item.player.id != bestTargets.first?.player.id {
                        Divider().background(Theme.border)
                    }
                    NavigationLink {
                        TrackedPlayerDetailView(trackedID: item.player.id, actor: actor)
                    } label: {
                        bestTargetRow(item.player, item.a)
                    }
                    .buttonStyle(.plain)
                }
            }
            .cardStyle(padding: 0)
        }
    }

    private func bestTargetRow(_ p: TrackedPlayer, _ a: TargetAssessment) -> some View {
        HStack(spacing: Space.md) {
            ScoreBadge(score: a.score, band: a.band, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.sm) {
                    Text(p.username).font(.bodyStrong)
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    TagPill(label: a.activity.label, color: ScoreStyle.activityColor(a.activity))
                }
                Text("Lv \(p.level ?? 0) · \(CryptoFormat.compact(p.cryptoHot)) held · \(CryptoFormat.compact(a.totals.extractedTotal)) taken")
                    .font(.caption).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 13)).foregroundStyle(Theme.textFaint)
        }
        .padding(Space.md)
        .contentShape(Rectangle())
    }

    private var biggestEarners: some View {
        let maxEarned = topEarners.map { $0.total }.max() ?? 1
        return DashSection(title: "Biggest earners", subtitle: "Crypto taken, all time") {
            VStack(spacing: Space.md) {
                ForEach(topEarners, id: \.player.id) { item in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack {
                            Text(item.player.username).font(.labelM)
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Spacer()
                            Text(CryptoFormat.compact(item.total))
                                .font(.labelM).foregroundStyle(Theme.crypto)
                        }
                        RankBar(value: item.total, max: maxEarned)
                    }
                }
            }
            .cardStyle()
        }
    }

    private var targetActivity: some View {
        let order: [ActivityState] = [.active, .semiActive, .review, .inactive]
        return DashSection(title: "Target activity") {
            VStack(alignment: .leading, spacing: Space.md) {
                BreakdownBar(segments: order.map {
                    .init(value: activityCounts[$0] ?? 0, color: ScoreStyle.activityColor($0))
                })
                HStack(spacing: Space.md) {
                    ForEach(order, id: \.self) { s in
                        HStack(spacing: Space.xs) {
                            Circle().fill(ScoreStyle.activityColor(s)).frame(width: 8, height: 8)
                            Text("\(s.label) \(activityCounts[s] ?? 0)")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .cardStyle()
        }
    }

    private var database: some View {
        DashSection(title: "Database") {
            VStack(spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    MetricTile(label: "Targets", value: "\(store.players.count)")
                    MetricTile(label: "IPs", value: "\(store.players.filter { $0.currentIP?.isEmpty == false }.count)")
                    MetricTile(label: "Wallets", value: "\(store.players.filter { $0.walletAddress?.isEmpty == false }.count)")
                }
                HStack(spacing: Space.sm) {
                    MetricTile(label: "Extractions", value: "\(totals.eventCount)")
                    MetricTile(label: "Software", value: "\(store.players.reduce(0) { $0 + $1.software.count })")
                    MetricTile(label: "Last capture", value: lastCaptureRelative)
                }
            }
        }
    }
}

/// Section wrapper: title + optional subtitle + optional trailing action.
private struct DashSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var action: (() -> Void)? = nil
    var actionLabel: String = "See all"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.heading).foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer()
                if let action {
                    Button(actionLabel, action: action)
                        .font(.labelM).foregroundColor(Theme.accent)
                }
            }
            content
        }
    }
}

/// Compact metric card (label over value), sized to share a row equally.
private struct MetricTile: View {
    let label: String
    let value: String
    var color: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption).foregroundStyle(Theme.textFaint)
            Text(value).font(.titleXL).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: Space.md)
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
