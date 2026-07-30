import SwiftUI

struct LoginView: View {
    let error: SessionManager.LoginError?
    @EnvironmentObject private var session: SessionManager
    @State private var signingIn = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 6) {
                Text("K3RN Intel")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Crew intelligence database")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }

            if let error {
                ErrorBanner(message: error.message).padding(.horizontal)
            }

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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent)
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(signingIn)
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .padding()
    }
}

struct PendingView: View {
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        GateScreen(
            icon: "clock.badge.questionmark",
            title: "Waiting for approval",
            message: "Your account is verified but needs an admin to grant access. Pull to refresh once you've been approved.",
            primaryLabel: "Refresh",
            primaryAction: { await session.refreshProfile() }
        )
    }
}

struct DisabledView: View {
    var body: some View {
        GateScreen(
            icon: "nosign",
            title: "Access disabled",
            message: "Your account has been disabled. Contact a crew admin if you think this is a mistake.",
            primaryLabel: nil,
            primaryAction: nil
        )
    }
}

struct NotInCrewView: View {
    var body: some View {
        GateScreen(
            icon: "person.fill.xmark",
            title: "Not in the crew",
            message: "You must be a member of the crew Discord with the required role to use K3RN Intel.",
            primaryLabel: nil,
            primaryAction: nil
        )
    }
}

/// Shared layout for the pending/disabled/not-in-crew screens, all of which
/// offer a sign-out and an optional primary action.
private struct GateScreen: View {
    let icon: String
    let title: String
    let message: String
    let primaryLabel: String?
    let primaryAction: (() async -> Void)?

    @EnvironmentObject private var session: SessionManager
    @State private var working = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()

            if let primaryLabel, let primaryAction {
                Button {
                    working = true
                    Task { await primaryAction(); working = false }
                } label: {
                    HStack {
                        if working { ProgressView().tint(.black) }
                        Text(primaryLabel).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.accent)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(working)
                .padding(.horizontal)
            }

            Button("Sign out") { Task { await session.signOut() } }
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 32)
        }
        .padding()
    }
}
