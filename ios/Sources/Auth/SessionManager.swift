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

    /// Errors from the email fallback flow. Deliberately separate from `LoginError`:
    /// these are shown inside the email sheet, whereas `LoginError` lives in
    /// `.signedOut` and makes `RootView` rebuild `LoginView` — which would tear the
    /// sheet down mid-typing.
    enum EmailAuthError: Equatable {
        case invalidCredentials
        case invalidCode
        case rateLimited
        case weakPassword(String)
        case emailNotConfirmed
        case other(String)

        var message: String {
            switch self {
            case .invalidCredentials:
                // The server returns the same code for "wrong password" and "this
                // account has no password yet", so the copy must cover both.
                return "Wrong email or password — or this account doesn't have a password yet. Use \"Set or reset password\" below."
            case .invalidCode:
                return "That code is wrong or has expired. Request a new one."
            case .rateLimited:
                return "Too many attempts. Wait a minute and try again."
            case let .weakPassword(reason):
                return reason
            case .emailNotConfirmed:
                return "This email hasn't been confirmed yet."
            case let .other(message):
                return message
            }
        }
    }

    enum State: Equatable {
        case loading
        case signedOut(LoginError?)
        case notInCrew
        case pending
        case disabled
        case mustSetPassword
        case ready(Profile, Actor)

        static func == (l: State, r: State) -> Bool {
            switch (l, r) {
            case (.loading, .loading), (.notInCrew, .notInCrew),
                 (.pending, .pending), (.disabled, .disabled),
                 (.mustSetPassword, .mustSetPassword):
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

    /// Set synchronously the moment a recovery session is redeemed, so an in-flight
    /// `bootstrap()` racing a cold launch from the emailed link cannot route past the
    /// "choose a password" screen. Checked after every `await` that precedes a
    /// `state` write. Cleared only by `setNewPassword` succeeding, or by `signOut`.
    private var recoveryLatch = false

    private var client: SupabaseClient { SupabaseManager.client }

    /// Called on launch. Restores an existing session if present. The provider
    /// token isn't available on restore, so we skip the Discord gate and route
    /// purely by the stored profile role (RLS still enforces access).
    func bootstrap() async {
        if recoveryLatch { state = .mustSetPassword; return }
        do {
            let session = try await client.auth.session
            if recoveryLatch { state = .mustSetPassword; return }
            await routeByProfile(userID: session.user.id.uuidString)
        } catch {
            if recoveryLatch { state = .mustSetPassword; return }
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
        recoveryLatch = false
        try? await client.auth.signOut()
        recoveryLatch = false
        state = .signedOut(nil)
    }

    // MARK: - Email fallback
    //
    // Discord OAuth stays the primary sign-in. These exist because Discord's web
    // bundle no longer boots on iOS 15 WebKit, leaving the consent page blank on
    // older devices. The OAuth flow requests the `email` scope, so `auth.users.email`
    // is already populated and these resolve to the *same* auth user — the existing
    // `profiles` row, role and `discord_user_id` are preserved.

    /// Password sign-in. Skips `DiscordGate` deliberately: there is no provider token
    /// on this path, `bootstrap()` already skips the gate on every warm launch, and
    /// the gate is UX-only — RLS is the real boundary.
    func signInWithEmail(email: String, password: String) async -> EmailAuthError? {
        let session: Session
        do {
            session = try await client.auth.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
        } catch {
            return mapAuthError(error)
        }
        state = .loading
        await routeByProfile(userID: session.user.id.uuidString)
        return nil
    }

    /// Sends a recovery email containing both a 6-digit code and a deep link.
    /// Returns `nil` for an unknown address too — GoTrue answers 200 either way and
    /// the UI must not leak whether an account exists.
    func sendPasswordReset(to email: String) async -> EmailAuthError? {
        do {
            try await client.auth.resetPasswordForEmail(
                email.trimmingCharacters(in: .whitespacesAndNewlines),
                redirectTo: AppConfig.authRedirect
            )
            return nil
        } catch {
            return mapAuthError(error)
        }
    }

    /// Redeems the 6-digit code from the recovery email. Preferred over the deep
    /// link: no PKCE device binding, no cold-launch race, and immune to mail clients
    /// that prefetch the one-time link.
    func redeemRecoveryCode(email: String, code: String) async -> EmailAuthError? {
        do {
            _ = try await client.auth.verifyOTP(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                token: code.trimmingCharacters(in: .whitespacesAndNewlines),
                type: .recovery
            )
        } catch {
            // On this screen a rejected credential is always a bad code — never
            // show the sign-in copy pointing at "set or reset password".
            let mapped = mapAuthError(error)
            return mapped == .invalidCredentials ? .invalidCode : mapped
        }
        recoveryLatch = true
        state = .mustSetPassword
        return nil
    }

    /// Deep-link half of the recovery flow. Under PKCE the callback carries only
    /// `?code=`, with no `type=recovery` to inspect and no `.passwordRecovery` event
    /// — so any successful exchange here is treated as a recovery. That is safe:
    /// Discord's OAuth resolves inside `ASWebAuthenticationSession` and never reaches
    /// `.onOpenURL`, so this is only ever hit by a reset link.
    func handleAuthCallback(_ url: URL) async {
        guard AppConfig.isAuthCallback(url) else { return }
        recoveryLatch = true
        state = .loading
        do {
            _ = try await client.auth.session(from: url)
            recoveryLatch = true
            state = .mustSetPassword
        } catch {
            recoveryLatch = false
            await bootstrap()
        }
    }

    /// Completes recovery. For a Discord-only account this is first-time password
    /// setup rather than a change.
    func setNewPassword(_ password: String) async -> EmailAuthError? {
        let userID: String
        do {
            _ = try await client.auth.update(user: UserAttributes(password: password))
            userID = try await client.auth.session.user.id.uuidString
        } catch {
            return mapAuthError(error)
        }
        recoveryLatch = false
        state = .loading
        await routeByProfile(userID: userID)
        return nil
    }

    private func mapAuthError(_ error: Error) -> EmailAuthError {
        guard let authError = error as? AuthError else {
            return .other("Network error. Check your connection and try again.")
        }
        switch authError.errorCode {
        case .invalidCredentials, .userNotFound:
            return .invalidCredentials
        case .otpExpired, .flowStateExpired, .flowStateNotFound:
            return .invalidCode
        case .overRequestRateLimit, .overEmailSendRateLimit:
            return .rateLimited
        case .weakPassword, .samePassword:
            return .weakPassword(authError.message)
        case .emailNotConfirmed:
            return .emailNotConfirmed
        default:
            return .other(authError.message)
        }
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
        if recoveryLatch { state = .mustSetPassword; return }
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
            if recoveryLatch { state = .mustSetPassword; return }
            state = .pending
            return
        }
        if recoveryLatch { state = .mustSetPassword; return }

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
