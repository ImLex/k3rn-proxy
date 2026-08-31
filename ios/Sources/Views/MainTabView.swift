import SwiftUI

enum AppTab: CaseIterable {
    case dashboard, targets, scan, virus, search, k3rn, settings

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .targets: return "Targets"
        case .scan: return "Scan"
        case .virus: return "Virus"
        case .search: return "Search"
        case .k3rn: return "Crews"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .targets: return "person.2.fill"
        case .scan: return "dot.radiowaves.left.and.right"
        case .virus: return "ladybug.fill"
        case .search: return "magnifyingglass"
        case .k3rn: return "globe"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MainTabView: View {
    /// Both nil in signed-out "browse offline" mode — the personal tabs render
    /// from the local cache and the database-backed tabs show a sign-in gate.
    let profile: Profile?
    let actor: Actor?
    @EnvironmentObject private var nicknames: NicknameStore
    @State private var tab: AppTab = .dashboard

    var body: some View {
        // A real VStack, not `.safeAreaInset(edge: .bottom)`: on iOS 15 that inset
        // does not reach inside a child NavigationView, so each tab's content area
        // stayed full-height and anything it anchored to its own bottom edge was
        // painted behind KTabBar (see the Targets edit bar).
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            KTabBar(selection: $tab)
        }
        .task { if actor != nil { await nicknames.refreshIfStale() } }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .dashboard: DashboardView(actor: actor)
        case .targets: TrackerView(actor: actor)
        case .scan:
            if let actor { ScanView(actor: actor) } else { SignInGate(feature: "the target scanner") }
        case .virus: VirusView(actor: actor)
        case .search:
            if let actor { SearchView(actor: actor) } else { SignInGate(feature: "the crew player database") }
        case .k3rn:
            if let actor { CrewsView(actor: actor) } else { SignInGate(feature: "crew rosters") }
        case .settings:
            if let profile, let actor { SettingsView(profile: profile, actor: actor) }
            else { SignInGate(feature: "your account and device setup") }
        }
    }
}

/// Shown on database-backed tabs while browsing offline. Only signing in unlocks
/// them — the personal tracker stays usable without an account.
struct SignInGate: View {
    let feature: String
    @EnvironmentObject private var session: SessionManager
    @State private var signingIn = false
    @State private var showEmailSignIn = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 52)).foregroundStyle(Theme.accent)
            Text("Sign in to access \(feature)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            Text("Your tracked targets stay available offline. Signing in only unlocks the shared crew database.")
                .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            Spacer()
            Button {
                signingIn = true
                Task { await session.signIn(); signingIn = false }
            } label: {
                HStack {
                    if signingIn { ProgressView().tint(.black) }
                    else { Image(systemName: "person.badge.key.fill") }
                    Text("Sign in with Discord").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(signingIn)
            .padding(.horizontal)

            OrDivider().padding(.horizontal)

            Button("Sign in with email") { showEmailSignIn = true }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: $showEmailSignIn) {
            EmailSignInView().environmentObject(session)
        }
    }
}

/// Custom bottom tab bar mirroring the Android app (6 tabs, accent/faint tints,
/// surface background with a 1px top border). Built custom because a native
/// iOS TabView collapses the 5th+ item into a "More" menu.
struct KTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { item in
                let isSel = item == selection
                Button {
                    selection = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 20))
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(isSel ? Theme.accent : Theme.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 2)
        .background(
            Theme.surface
                .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
