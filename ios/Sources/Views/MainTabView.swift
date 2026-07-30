import SwiftUI

struct MainTabView: View {
    let profile: Profile
    let actor: Actor
    @EnvironmentObject private var nicknames: NicknameStore

    var body: some View {
        TabView {
            DashboardView(actor: actor)
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2.fill") }

            SearchView(actor: actor)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            TrackerView(actor: actor)
                .tabItem { Label("Tracker", systemImage: "scope") }

            CrewsView(actor: actor)
                .tabItem { Label("Crews", systemImage: "person.3.fill") }

            ActivityView()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }

            SettingsView(profile: profile, actor: actor)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .task { await nicknames.refreshIfStale() }
    }
}
