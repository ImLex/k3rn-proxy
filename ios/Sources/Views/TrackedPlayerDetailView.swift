import SwiftUI

/// A single tracked target: private stats + captured software, plus the explicit
/// "Upload to crew DB" action (promotes it into the shared players table).
struct TrackedPlayerDetailView: View {
    let trackedID: String
    let actor: Actor
    @EnvironmentObject private var store: TrackerStore

    @State private var working = false
    @State private var errorMessage: String?

    private var player: TrackedPlayer? { store.player(id: trackedID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let msg = errorMessage { ErrorBanner(message: msg) }
                if let p = player {
                    header(p)
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

    private func header(_ p: TrackedPlayer) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.username)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                if let crew = p.crew, !crew.isEmpty {
                    Text(crew).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if p.isUploaded {
                Label("Uploaded", systemImage: "checkmark.icloud")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.18))
                    .foregroundStyle(Theme.accent)
                    .clipShape(Capsule())
            }
        }
    }

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

            Text("Shares this player with the whole crew. Your captured software list stays personal.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }

    private func valueText(_ v: Int?) -> some View {
        Text(v.map(String.init) ?? "—").font(.mono(14)).foregroundStyle(Theme.textPrimary)
    }

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
