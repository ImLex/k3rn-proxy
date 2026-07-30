import SwiftUI

enum AppTab: CaseIterable {
    case dashboard, targets, virus, search, k3rn, settings

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .targets: return "Targets"
        case .virus: return "Virus"
        case .search: return "Search"
        case .k3rn: return "K3RN"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .targets: return "person.2.fill"
        case .virus: return "ladybug.fill"
        case .search: return "magnifyingglass"
        case .k3rn: return "globe"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MainTabView: View {
    let profile: Profile
    let actor: Actor
    @EnvironmentObject private var nicknames: NicknameStore
    @State private var tab: AppTab = .dashboard

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                KTabBar(selection: $tab)
            }
            .task { await nicknames.refreshIfStale() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .dashboard: DashboardView(actor: actor)
        case .targets: TrackerView(actor: actor)
        case .virus: VirusView(actor: actor)
        case .search: SearchView(actor: actor)
        case .k3rn: CrewsView(actor: actor)
        case .settings: SettingsView(profile: profile, actor: actor)
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
