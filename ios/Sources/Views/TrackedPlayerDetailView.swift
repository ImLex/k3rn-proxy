import SwiftUI

/// A single tracked target: full scoring readout (potential score, tier, trend,
/// recommendation), crypto history, private stats + captured software, plus the
/// explicit "Upload to crew DB" action (promotes it into the shared players table).
struct TrackedPlayerDetailView: View {
    let trackedID: String
    let actor: Actor
    @EnvironmentObject private var store: TrackerStore
    @AppStorage("user_level") private var userLevel = 0

    @State private var working = false
    @State private var errorMessage: String?

    private var player: TrackedPlayer? { store.player(id: trackedID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if let msg = errorMessage { ErrorBanner(message: msg) }
                if let p = player {
                    let events = store.events(for: p)
                    let a = TargetAssessor.assess(player: p, events: events, userLevel: userLevel)
                    scoreHeader(p, a)
                    cryptoCard(p, a)
                    statsGrid(a.totals)
                    if !events.isEmpty { historyCard(events) }
                    breakdownCard(a)
                    fields(p)
                    if !p.software.isEmpty { softwareSection(p) }
                    uploadSection(p)
                } else {
                    EmptyState(systemImage: "scope", title: "Target not found")
                }
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle(player?.username ?? "Target")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: score header

    private func scoreHeader(_ p: TrackedPlayer, _ a: TargetAssessment) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                ScoreBadge(score: a.score, band: a.band, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.username)
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text("\(a.band.label) target")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ScoreStyle.bandColor(a.band))
                    if let crew = p.crew, !crew.isEmpty {
                        Text(crew).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: Space.xs) {
                TagPill(label: "Do: \(a.recommendation.label)",
                        color: ScoreStyle.recommendationColor(a.recommendation))
                TagPill(label: a.activity.label, color: ScoreStyle.activityColor(a.activity))
                trendPill(a.trend)
            }
        }
        .cardStyle()
    }

    private func trendPill(_ t: YieldTrend) -> some View {
        let label: String
        if let pct = t.percent, t.direction != .unknown {
            label = "\(t.direction.rawValue.capitalized) \(pct > 0 ? "+" : "")\(pct)%"
        } else {
            label = "Trend —"
        }
        return HStack(spacing: 3) {
            Image(systemName: ScoreStyle.trendIcon(t.direction)).font(.system(size: 9, weight: .bold))
            Text(label.uppercased()).font(.system(size: 10, weight: .bold))
        }
        .foregroundColor(ScoreStyle.trendColor(t.direction))
        .padding(.vertical, 3).padding(.horizontal, Space.sm)
        .background(ScoreStyle.trendColor(t.direction).opacity(0.15))
        .clipShape(Capsule())
    }

    // MARK: crypto held

    private func cryptoCard(_ p: TrackedPlayer, _ a: TargetAssessment) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                SectionHeader(title: "Crypto held")
                Spacer()
                if let updated = p.cryptoUpdatedAt {
                    Text(Formatting.relativeTime(updated))
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
            }
            HStack(spacing: Space.md) {
                walletStat("HOT (STEALABLE)", p.cryptoHot, Theme.crypto)
                walletStat("COLD (SAFE)", p.cryptoCold, Theme.textSecondary)
            }
            HStack(spacing: Space.xs) {
                if let t = a.currentTier {
                    TagPill(label: "Now \(t.label)", color: ScoreStyle.tierColor(t))
                }
                if let t = a.yieldTier {
                    TagPill(label: "Yield \(t.label)", color: ScoreStyle.tierColor(t))
                }
            }
            if let addr = p.walletAddress, !addr.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WALLET ADDRESS")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textFaint)
                    CopyableIP(ip: addr, font: .mono(12))
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardStyle()
    }

    private func walletStat(_ label: String, _ value: Double?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CryptoFormat.compact(value)).font(.mono(20, weight: .bold)).foregroundStyle(color)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: totals grid

    private func statsGrid(_ t: CryptoTotals) -> some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                miniStat("EXTRACTED", CryptoFormat.compact(t.extractedTotal), Theme.crypto)
                miniStat("RATE/DAY", CryptoFormat.compact(t.averagePerActiveDay), Theme.accent)
                miniStat("EVENTS", "\(t.eventCount)", Theme.textPrimary)
            }
            HStack(spacing: Space.sm) {
                miniStat("TODAY", CryptoFormat.compact(t.extractedToday), Theme.textSecondary)
                miniStat("7 DAYS", CryptoFormat.compact(t.extracted7Days), Theme.textSecondary)
                miniStat("30 DAYS", CryptoFormat.compact(t.extracted30Days), Theme.textSecondary)
            }
        }
    }

    private func miniStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.mono(16, weight: .semibold)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: Space.md)
    }

    // MARK: history sparkline

    private func historyCard(_ events: [CryptoEvent]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Theft history")
            Sparkline(values: events.sorted { $0.date < $1.date }.map(\.amount))
                .frame(height: 56)
            HStack {
                Text("\(events.count) extraction\(events.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                Spacer()
                if let last = events.map(\.date).max() {
                    Text("last \(Formatting.relativeTime(iso(last)))")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
            }
        }
        .cardStyle()
    }

    // MARK: score breakdown

    private func breakdownCard(_ a: TargetAssessment) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Why this score")
            ForEach(a.breakdown.components) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(c.label).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("+\(CryptoFormat.trim(c.weighted * 100)) pts")
                            .font(.mono(12)).foregroundStyle(Theme.textSecondary)
                    }
                    ProgressBar(progress: c.value, color: ScoreStyle.bandColor(a.band), height: 5)
                }
            }
            Text("Weighted 0–100 potential score across current value, refill speed, proven yield, activity, soft defences and device.")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
        }
        .cardStyle()
    }

    // MARK: fields

    private func fields(_ p: TrackedPlayer) -> some View {
        VStack(spacing: 2) {
            DetailRow(label: "Player ID") {
                Text(p.playerID ?? "—").font(.mono(14)).foregroundStyle(Theme.textPrimary)
            }
            DetailRow(label: "Current IP") { CopyableIP(ip: p.currentIP) }
            DetailRow(label: "Level") { valueText(p.level) }
            DetailRow(label: "Firewall") { valueText(p.firewall) }
            DetailRow(label: "Reputation") { valueText(p.reputation) }
            DetailRow(label: "Captured") {
                Text(Formatting.absoluteTime(p.capturedAt))
                    .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
            }
        }
        .cardStyle()
    }

    private func softwareSection(_ p: TrackedPlayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Software")
            ForEach(p.software) { sw in
                HStack {
                    Text(sw.name).font(.system(size: 15)).foregroundStyle(Theme.textPrimary)
                    if let cat = sw.category, !cat.isEmpty {
                        Text(cat).font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Text("Lv \(sw.level)").font(.mono(13)).foregroundStyle(Theme.textSecondary)
                }
                .cardStyle()
            }
        }
    }

    private func uploadSection(_ p: TrackedPlayer) -> some View {
        VStack(spacing: 8) {
            Button {
                Task { await upload(p) }
            } label: {
                HStack {
                    if working { ProgressView() }
                    else { Image(systemName: p.isUploaded ? "arrow.triangle.2.circlepath" : "square.and.arrow.up") }
                    Text(p.isUploaded ? "Re-upload to crew DB" : "Upload to crew DB")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(Theme.accent)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.5)))
            }
            .disabled(working)

            Text("Shares this player with the whole crew. Your captured software list and theft history stay personal.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }

    private func valueText(_ v: Int?) -> some View {
        Text(v.map(String.init) ?? "—").font(.mono(14)).foregroundStyle(Theme.textPrimary)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private func iso(_ d: Date) -> String { Self.iso.string(from: d) }

    private func upload(_ p: TrackedPlayer) async {
        working = true
        defer { working = false }
        errorMessage = nil
        do {
            let input = PlayerInput(
                username: p.username,
                playerID: p.playerID,
                crew: p.crew,
                crewRank: (p.crew?.isEmpty == false) ? CrewRank.member.rawValue : nil,
                currentIP: p.currentIP,
                level: p.level,
                firewall: p.firewall,
                reputation: p.reputation,
                notes: nil
            )
            if let existing = try await PlayerService.findExisting(playerID: p.playerID, username: p.username) {
                _ = try await PlayerService.update(id: existing.id, input: input, actor: actor)
            } else {
                _ = try await PlayerService.create(input, actor: actor)
            }
            try await CaptureService.markUploaded(id: p.id)
            store.markUploaded(id: p.id)
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
    }
}

/// Minimal bar sparkline for the theft history — one bar per extraction,
/// chronological, height proportional to amount. iOS-15 friendly (no Charts).
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            let count = max(values.count, 1)
            let gap: CGFloat = 2
            let barW = max((geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(Theme.crypto.opacity(0.85))
                        .frame(width: barW,
                               height: max(geo.size.height * CGFloat(v / maxV), 2))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}
