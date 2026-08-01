import SwiftUI
import Supabase
#if canImport(UIKit)
import UIKit
#endif

@main
struct K3RNIntelApp: App {
    @StateObject private var session = SessionManager()
    @StateObject private var nicknames = NicknameStore()
    @StateObject private var tracker = TrackerStore()
    @StateObject private var scanStore = ScanStore()

    init() {
        // iOS 15 has no .scrollContentBackground(.hidden); clear the List/table
        // background globally so Theme.background shows through (see hideScrollBackground()).
        #if canImport(UIKit)
        UITableView.appearance().backgroundColor = .clear
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(nicknames)
                .environmentObject(tracker)
                .environmentObject(scanStore)
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
