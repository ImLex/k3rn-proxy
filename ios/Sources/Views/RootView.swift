import SwiftUI

/// Top-level router driven by SessionManager.state (guide §3).
struct RootView: View {
    @EnvironmentObject private var session: SessionManager
    /// Set when the user chooses "Continue offline" — shows the app shell with
    /// only the personal (cached) tabs usable and the database tabs gated.
    @State private var browseOffline = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch session.state {
            case .loading:
                ProgressView().tint(Theme.accent)
            case let .signedOut(error):
                if browseOffline {
                    MainTabView(profile: nil, actor: nil)
                } else {
                    LoginView(error: error, onBrowseOffline: { browseOffline = true })
                }
            case .notInCrew:
                NotInCrewView()
            case .pending:
                PendingView()
            case .disabled:
                DisabledView()
            case .mustSetPassword:
                SetPasswordView()
            case let .ready(profile, actor):
                MainTabView(profile: profile, actor: actor)
            }
        }
        .animation(.default, value: session.state)
        .onChange(of: session.state) { _ in browseOffline = false }
    }
}
