import SwiftUI

struct SettingsView: View {
    let profile: Profile
    let actor: Actor
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var tracker: TrackerStore
    @EnvironmentObject private var scanStore: ScanStore
    @AppStorage("user_level") private var userLevel = 0
    @AppStorage("active_game_pid") private var activePID = ""

    private var isAdmin: Bool { actor.role == .admin }

    /// The game account currently selected on the Dashboard switcher.
    private var activeAccount: OwnProfile? {
        tracker.ownAccounts.first { $0.id == activePID } ?? tracker.ownAccounts.first
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    accountCard
                    connectionCard
                    gameAccountCard
                    NavigationLink {
                        TunnelSetupView()
                    } label: {
                        HStack {
                            Label("Connect device (VPN)", systemImage: "network.badge.shield.half.filled")
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                        }
                        .cardStyle()
                    }
                    .buttonStyle(.plain)
                    levelCard
                    if isAdmin {
                        NavigationLink {
                            UserManagementView(currentUserID: profile.userID)
                        } label: {
                            HStack {
                                Label("User management", systemImage: "person.2.badge.gearshape")
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                            }
                            .cardStyle()
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        Task { await session.signOut() }
                    } label: {
                        Text("Sign out").fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .foregroundStyle(Theme.accent)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.5)))
                    }

                    Button(role: .destructive) {
                        tracker.clear()
                        scanStore.clear()
                        Task { await session.signOut() }
                    } label: {
                        Text("Sign out & clear data").fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .foregroundStyle(.red)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.red.opacity(0.5)))
                    }

                    Text("Sign out keeps your tracked targets on this device for offline viewing. Clear data wipes them — use it on a shared phone.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("build \(AppConfig.buildRevision)")
                        .font(.mono(11)).foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Settings")
            .refreshable { await tracker.refresh(); syncLevel() }
        }
        .task { await tracker.refresh(); syncLevel() }
    }

    /// The game is the source of truth: once /v1/user is captured, adopt the
    /// active account's level.
    private func syncLevel() {
        if let lvl = activeAccount?.level, lvl > 0 { userLevel = lvl }
    }

    // MARK: connection health

    /// Derived from `peer_heartbeats.last_seen_at`. The addon stamps that row on
    /// every mapped GAME_HOST response (see migration 0028), so a fresh
    /// timestamp proves the phone → WG → mitmproxy → Supabase path is alive.
    /// Distinct from `own_profile.captured_at`, which only advances when the
    /// game hits /v1/user (member taps their own profile).
    private enum ConnectionStatus {
        case live(Date)     // heartbeat < 60s
        case idle(Date)     // heartbeat < 10 min
        case lost(Date?)    // older, or never stamped
    }

    private var connectionStatus: ConnectionStatus {
        guard let raw = tracker.heartbeat?.lastSeenAt,
              let d = Formatting.date(from: raw) else { return .lost(nil) }
        let age = Date().timeIntervalSince(d)
        if age < 60 { return .live(d) }
        if age < 600 { return .idle(d) }
        return .lost(d)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: "Connection")
                Button {
                    Task { await tracker.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(tracker.loading)
            }
            connectionStatusRow
            connectionDetail
        }
        .cardStyle()
    }

    @ViewBuilder private var connectionStatusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusLabel)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(statusRelative)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder private var connectionDetail: some View {
        switch connectionStatus {
        case .live:
            Text("The proxy is seeing your HackEx traffic right now.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        case .idle:
            Text("No game traffic in the last minute. Open HackEx to refresh.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        case .lost:
            VStack(alignment: .leading, spacing: 6) {
                Text("The proxy isn't seeing your game. Try in order:")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                lostStep("1. Toggle the WireGuard tunnel off, then back on.")
                lostStep("2. Force-quit HackEx and reopen it. iOS caches DNS across launches, and the game may be using an IP outside the tunnel.")
                lostStep("3. If it's still Lost after ~30 seconds, re-provision the tunnel below.")
            }
        }
    }

    private func lostStep(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch connectionStatus {
        case .live: return Theme.success
        case .idle: return Theme.warning
        case .lost: return Theme.danger
        }
    }

    private var statusLabel: String {
        switch connectionStatus {
        case .live: return "Live"
        case .idle: return "Idle"
        case .lost: return "Lost"
        }
    }

    private var statusRelative: String {
        switch connectionStatus {
        case .live(let d), .idle(let d): return Formatting.relativeTime(from: d)
        case .lost(let d):
            return d.map { Formatting.relativeTime(from: $0) } ?? "never"
        }
    }

    // MARK: own in-game account (captured from the API)

    private var gameAccountCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Game account")
                if tracker.ownAccounts.count > 1 {
                    Text("\(tracker.ownAccounts.count) accounts · switch on Dashboard")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                }
            }
            if let p = activeAccount {
                if let u = p.username {
                    DetailRow(label: "Username") {
                        Text(u).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    }
                }
                DetailRow(label: "Level") { valueMono(p.level) }
                DetailRow(label: "Device") {
                    Text(p.device ?? "—").font(.mono(14)).foregroundStyle(Theme.textPrimary)
                }
                DetailRow(label: "Reputation") { valueMono(p.reputation) }
                DetailRow(label: "Firewall") { valueMono(p.firewall) }
                DetailRow(label: "Crypto (hot / cold)") {
                    Text("\(CryptoFormat.compact(p.cryptoHot)) / \(CryptoFormat.compact(p.cryptoCold))")
                        .font(.mono(14)).foregroundStyle(Theme.crypto)
                }
                if !p.software.isEmpty {
                    DetailRow(label: "Software") {
                        Text("\(p.software.count)").font(.mono(14)).foregroundStyle(Theme.textPrimary)
                    }
                }
                DetailRow(label: "Captured") {
                    Text(Formatting.relativeTime(p.capturedAt))
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text("Open your own profile in-game with the VPN on and it syncs here.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardStyle()
    }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Your level")
            if let lvl = activeAccount?.level, lvl > 0 {
                DetailRow(label: "Level") {
                    Text("\(lvl)").font(.mono(15, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                Text("Synced from your game account. Used to tailor spam/siphon recommendations to the level gap.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            } else {
                Stepper(value: $userLevel, in: 0...300) {
                    HStack {
                        Text("Level").foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(userLevel == 0 ? "Not set" : "\(userLevel)")
                            .font(.mono(15, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
                Text("Set manually until your account syncs from the game. Tailors spam/siphon recommendations to the level gap.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .cardStyle()
    }

    private func valueMono(_ v: Int?) -> some View {
        Text(v.map(String.init) ?? "—").font(.mono(14)).foregroundStyle(Theme.textPrimary)
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(profile.nickname ?? profile.displayName ?? profile.discordUsername ?? "Account")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                RoleBadge(role: profile.role)
            }
            DetailRow(label: "Discord") {
                Text(profile.discordUsername ?? "—").foregroundStyle(Theme.textPrimary)
            }
            if let nick = profile.nickname {
                DetailRow(label: "Nickname") { Text(nick).foregroundStyle(Theme.textPrimary) }
            }
            DetailRow(label: "Verified") {
                Text(Formatting.absoluteTime(profile.verifiedAt)).foregroundStyle(Theme.textPrimary)
                    .font(.system(size: 13))
            }
            DetailRow(label: "Approved") {
                Text(Formatting.absoluteTime(profile.approvedAt)).foregroundStyle(Theme.textPrimary)
                    .font(.system(size: 13))
            }
        }
        .cardStyle()
    }
}

struct RoleBadge: View {
    let role: Role
    var body: some View {
        Text(role.rawValue.uppercased())
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    private var color: Color {
        switch role {
        case .admin: return Theme.leader
        case .member: return Theme.accent
        case .pending: return Theme.officer
        case .disabled: return .red
        }
    }
}

// MARK: Admin user management

@MainActor
final class UserManagementModel: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var loading = true
    @Published var errorMessage: String?

    func load() async {
        errorMessage = nil
        do { profiles = try await ProfileService.allProfiles() }
        catch { errorMessage = AppError.map(error).errorDescription }
        loading = false
    }

    func approve(_ p: Profile, approver: String) async {
        await run { try await ProfileService.approve(userID: p.userID, approverUID: approver) }
    }
    func setRole(_ p: Profile, role: Role) async {
        await run { try await ProfileService.setRole(userID: p.userID, role: role) }
    }
    func setNickname(_ p: Profile, nickname: String) async {
        await run { try await ProfileService.setNickname(userID: p.userID, nickname: nickname) }
    }

    private func run(_ op: @escaping () async throws -> Void) async {
        do { try await op(); await load() }
        catch { errorMessage = AppError.map(error).errorDescription }
    }
}

struct UserManagementView: View {
    let currentUserID: String
    @StateObject private var model = UserManagementModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let msg = model.errorMessage { ErrorBanner(message: msg) }
                if model.profiles.isEmpty && !model.loading {
                    EmptyState(systemImage: "person.2", title: "No profiles")
                }
                ForEach(model.profiles) { p in
                    ProfileAdminCard(profile: p, isSelf: p.userID == currentUserID, model: model,
                                     approverUID: currentUserID)
                }
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { if model.loading { await model.load() } }
    }
}

struct ProfileAdminCard: View {
    let profile: Profile
    let isSelf: Bool
    @ObservedObject var model: UserManagementModel
    let approverUID: String
    @State private var nickname = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(profile.discordUsername ?? profile.displayName ?? "Unknown")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if isSelf {
                    Text("YOU").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                RoleBadge(role: profile.role)
            }

            if profile.role == .pending {
                Button("Approve") { Task { await model.approve(profile, approver: approverUID) } }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            }

            if !isSelf {
                Picker("Role", selection: Binding(
                    get: { profile.role },
                    set: { newRole in Task { await model.setRole(profile, role: newRole) } }
                )) {
                    ForEach([Role.pending, .member, .admin, .disabled], id: \.self) { r in
                        Text(r.rawValue.capitalized).tag(r)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                TextField("Nickname", text: $nickname)
                    .autocorrectionDisabled()
                    .font(.system(size: 14))
                Button("Set") { Task { await model.setNickname(profile, nickname: nickname) } }
                    .font(.system(size: 14)).foregroundStyle(Theme.accent)
                    .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .cardStyle()
        .onAppear { nickname = profile.nickname ?? "" }
    }
}
