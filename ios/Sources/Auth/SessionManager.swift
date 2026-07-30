import Foundation
import Supabase

/// Owns the auth lifecycle and routes the app to the right top-level screen
/// (IOS_APP_GUIDE §3). Drives RootView.
@MainActor
final class SessionManager: ObservableObject {
    enum LoginError: Equatable {
        case authFailed    // OAuth itself failed / was cancelled
        case verifyFailed  // signed in, but couldn't reach Discord to gate

        var message: String {
            switch self {
            case .authFailed: return "Sign-in failed. Please try again."
            case .verifyFailed: return "Couldn't verify your crew membership. Please try again."
            }
        }
    }

    enum State: Equatable {
        case loading
        case signedOut(LoginError?)
        case notInCrew
        case pending
        case disabled
        case ready(Profile, Actor)

        static func == (l: State, r: State) -> Bool {
            switch (l, r) {
            case (.loading, .loading), (.notInCrew, .notInCrew),
                 (.pending, .pending), (.disabled, .disabled):
                return true
            case let (.signedOut(a), .signedOut(b)):
                return a == b
            case let (.ready(pa, _), .ready(pb, _)):
                return pa.id == pb.id
            default:
                return false
            }
        }
    }

    @Published private(set) var state: State = .loading

    private var client: SupabaseClient { SupabaseManager.client }

    /// Called on launch. Restores an existing session if present. The provider
    /// token isn't available on restore, so we skip the Discord gate and route
    /// purely by the stored profile role (RLS still enforces access).
    func bootstrap() async {
        do {
            let session = try await client.auth.session
            await routeByProfile(userID: session.user.id.uuidString)
        } catch {
            state = .signedOut(nil)
        }
    }

    func signIn() async {
        state = .loading
        let session: Session
        do {
            session = try await client.auth.signInWithOAuth(
                provider: .discord,
                redirectTo: AppConfig.authRedirect,
                scopes: "identify email guilds guilds.members.read"
            )
        } catch {
            state = .signedOut(.authFailed)
            return
        }

        // Crew gate — must run now while the provider token is still available.
        if let token = session.providerToken {
            do {
                try await DiscordGate.verify(providerToken: token)
            } catch DiscordGate.GateError.notInCrew {
                try? await client.auth.signOut()
                state = .notInCrew
                return
            } catch {
                try? await client.auth.signOut()
                state = .signedOut(.verifyFailed)
                return
            }
        }
        // No provider token (shouldn't happen right after OAuth) → fall through
        // and rely on the profile role + RLS.

        await routeByProfile(userID: session.user.id.uuidString)
    }

    func signOut() async {
        try? await client.auth.signOut()
        state = .signedOut(nil)
    }

    /// Reload the current user's profile and re-route (used after admin role
    /// changes or pull-to-refresh on the pending screen).
    func refreshProfile() async {
        guard let userID = try? await client.auth.session.user.id.uuidString else {
            state = .signedOut(nil)
            return
        }
        await routeByProfile(userID: userID)
    }

    private func routeByProfile(userID: String) async {
        let profile: Profile
        do {
            profile = try await client
                .from("profiles")
                .select()
                .eq("user_id", value: userID)
                .single()
                .execute()
                .value
        } catch {
            // A brand-new signup may briefly 404 before handle_new_user commits,
            // or RLS may hide everything — treat as pending, the safest gate.
            state = .pending
            return
        }

        switch profile.role {
        case .pending:
            state = .pending
        case .disabled:
            state = .disabled
        case .member, .admin:
            state = .ready(profile, makeActor(profile))
        }
    }

    /// Actor identity for writes/audit (IOS_APP_GUIDE §6): id = discord id else
    /// auth uid; name = discord username else display name else email.
    private func makeActor(_ p: Profile) -> Actor {
        let id = p.discordUserID ?? p.userID
        let name = p.discordUsername ?? p.displayName ?? p.email ?? "app-user"
        return Actor(discordID: id, name: name, role: p.role)
    }
}
