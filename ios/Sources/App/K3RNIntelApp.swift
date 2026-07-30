import SwiftUI
import Supabase

@main
struct K3RNIntelApp: App {
    @StateObject private var session = SessionManager()
    @StateObject private var nicknames = NicknameStore()
    @StateObject private var tracker = TrackerStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(nicknames)
                .environmentObject(tracker)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await session.bootstrap() }
                .onOpenURL { url in
                    // OAuth custom-scheme callback (k3rnintel://auth-callback).
                    Task { try? await SupabaseManager.client.auth.session(from: url) }
                }
        }
    }
}
