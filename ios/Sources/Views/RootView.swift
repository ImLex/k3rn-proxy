import SwiftUI

/// Top-level router driven by SessionManager.state (guide §3).
struct RootView: View {
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch session.state {
            case .loading:
                ProgressView().tint(Theme.accent)
            case let .signedOut(error):
                LoginView(error: error)
            case .notInCrew:
                NotInCrewView()
            case .pending:
                PendingView()
            case .disabled:
                DisabledView()
            case let .ready(profile, actor):
                MainTabView(profile: profile, actor: actor)
            }
        }
        .animation(.default, value: session.state)
    }
}
