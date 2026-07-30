import SwiftUI

struct PlayerDetailView: View {
    let playerID: String
    let actor: Actor
    @EnvironmentObject private var nicknames: NicknameStore
    @Environment(\.dismiss) private var dismiss

    @State private var player: Player?
    @State private var ips: [PlayerIP] = []
    @State private var software: [InstalledSoftware] = []
    @State private var audit: [AuditLog] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var working = false

    private var isAdmin: Bool { actor.role == .admin }
    private var isDeleted: Bool { !(player?.deletedAt?.isEmpty ?? true) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let msg = errorMessage { ErrorBanner(message: msg) }
                if let player {
                    header(player)
                    fields(player)
                    ipHistorySection
                    if !software.isEmpty { softwareSection }
                    auditSection
                    if isAdmin { adminActions }
                } else if loading {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle(player?.username ?? "Player")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if player != nil && !isDeleted {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") { showEdit = true }
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            if let player {
                PlayerFormView(mode: .edit(player), actor: actor) { Task { await load() } }
            }
        }
        .confirmationDialog("Delete this player?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await softDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The player is soft-deleted and can be restored later.")
        }
        .task { await load() }
    }

    private func header(_ p: Player) -> some View {
        HStack(spacing: 10) {
            RankBadge(rank: p.rank)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.username)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                if let crew = p.crew, !crew.isEmpty {
                    Text("\(crew) · \(p.rank.rawValue.capitalized)")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if isDeleted {
                Text("DELETED")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.red.opacity(0.25))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            }
        }
    }

    private func fields(_ p: Player) -> some View {
        VStack(spacing: 2) {
            DetailRow(label: "Player ID") {
                Text(p.playerID ?? "—").font(.mono(14)).foregroundStyle(Theme.textPrimary)
            }
            DetailRow(label: "Current IP") { CopyableIP(ip: p.currentIP) }
            DetailRow(label: "Level") { valueText(p.level) }
            DetailRow(label: "Firewall") { valueText(p.firewall) }
            DetailRow(label: "Reputation") { valueText(p.reputation) }
            notesBlock(p)
            updatedBlock(p)
        }
        .cardStyle()
    }

    @ViewBuilder
    private func notesBlock(_ p: Player) -> some View {
        if let notes = p.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                Text(notes).font(.system(size: 15)).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 6)
        }
    }

    private func updatedBlock(_ p: Player) -> some View {
        DetailRow(label: "Updated") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatting.absoluteTime(p.updatedAt))
                    .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                Text("by \(nicknames.nickname(forDiscordID: p.updatedBy, fallback: p.updatedBy))")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var ipHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "IP History")
            if ips.isEmpty {
                EmptyState(systemImage: "network", title: "No IP history")
            } else {
                ForEach(ips) { ip in
                    HStack {
                        CopyableIP(ip: ip.ip)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("first \(Formatting.relativeTime(ip.firstSeen))")
                            Text("last \(Formatting.relativeTime(ip.lastSeen))")
                        }
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .cardStyle()
                }
            }
        }
    }

    private var softwareSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Software")
            ForEach(software) { sw in
                HStack {
                    Text(sw.software?.name ?? "Unknown")
                        .font(.system(size: 15)).foregroundStyle(Theme.textPrimary)
                    if sw.owner == "TARGET" {
                        Text("TARGET").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Text("Lv \(sw.level)").font(.mono(13)).foregroundStyle(Theme.textSecondary)
                }
                .cardStyle()
            }
        }
    }

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "History")
            if audit.isEmpty {
                EmptyState(systemImage: "clock", title: "No changes recorded")
            } else {
                ForEach(audit) { AuditRow(log: $0, nicknames: nicknames) }
            }
        }
    }

    private var adminActions: some View {
        VStack(spacing: 10) {
            if isDeleted {
                Button {
                    Task { await restore() }
                } label: {
                    actionLabel("Restore player", system: "arrow.uturn.backward", tint: Theme.accent)
                }
            } else {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    actionLabel("Delete player", system: "trash", tint: .red)
                }
            }
        }
        .disabled(working)
        .padding(.top, 8)
    }

    private func actionLabel(_ title: String, system: String, tint: Color) -> some View {
        HStack {
            if working { ProgressView() } else { Image(systemName: system) }
            Text(title).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .foregroundStyle(tint)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.5)))
    }

    private func valueText(_ v: Int?) -> some View {
        Text(v.map(String.init) ?? "—").font(.mono(14)).foregroundStyle(Theme.textPrimary)
    }

    private func load() async {
        errorMessage = nil
        do {
            async let p = PlayerService.fetch(id: playerID)
            async let i = PlayerService.ipHistory(playerID: playerID)
            async let s = SoftwareService.installed(playerID: playerID)
            async let a = PlayerService.auditTrail(playerID: playerID)
            player = try await p
            ips = try await i
            software = try await s
            audit = try await a
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
        loading = false
    }

    private func softDelete() async {
        working = true
        do { try await PlayerService.softDelete(id: playerID); await load() }
        catch { errorMessage = AppError.map(error).errorDescription }
        working = false
    }

    private func restore() async {
        working = true
        do { try await PlayerService.restore(id: playerID); await load() }
        catch { errorMessage = AppError.map(error).errorDescription }
        working = false
    }
}
