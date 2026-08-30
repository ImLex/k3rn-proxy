import SwiftUI
import UIKit
import Combine

// Email + password fallback for devices where Discord's web consent page no
// longer renders (iOS 15 WebKit). Discord OAuth remains the primary path; these
// screens are reached from the secondary button on LoginView / SignInGate.
//
// iOS 15 only: NavigationView (not NavigationStack), no .scrollDismissesKeyboard,
// forms wrapped in ScrollView so the keyboard can't clip the primary button.

/// Labelled text field styled on `Theme.surfaceRaised`, matching `cardStyle()`.
struct AuthField: View {
    let title: String
    var placeholder: String = ""
    @Binding var text: String
    var secure = false
    var textContentType: UITextContentType? = nil
    var keyboard: UIKeyboardType = .default
    var submitLabel: SubmitLabel = .next
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(.labelM)
                .foregroundColor(Theme.textSecondary)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textContentType(textContentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, Space.md)
            .frame(minHeight: 46)
            .background(Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
    }
}

// MARK: - Sign in

struct EmailSignInView: View {
    @EnvironmentObject private var session: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var error: SessionManager.EmailAuthError?
    @State private var working = false
    @State private var showReset = false

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Use the email address on your Discord account.")
                        .font(.bodyM)
                        .foregroundColor(Theme.textSecondary)

                    if let error {
                        ErrorBanner(message: error.message)
                    }

                    AuthField(
                        title: "Email",
                        placeholder: "you@example.com",
                        text: $email,
                        textContentType: .username,
                        keyboard: .emailAddress
                    )
                    AuthField(
                        title: "Password",
                        text: $password,
                        secure: true,
                        textContentType: .password,
                        submitLabel: .go,
                        onSubmit: { if canSubmit { submit() } }
                    )

                    KButton(label: "Sign in", loading: working, disabled: !canSubmit) {
                        submit()
                    }

                    // Always visible, not a small "forgot?" link: for a Discord-only
                    // account this is first-time setup, not a recovery.
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("First time here?")
                            .font(.bodyStrong)
                            .foregroundColor(Theme.textPrimary)
                        Text("Accounts created with Discord don't have a password yet. Set one to sign in without Discord.")
                            .font(.bodyM)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        KButton(label: "Set or reset password", variant: .secondary) {
                            showReset = true
                        }
                    }
                    .cardStyle()

                    Spacer(minLength: Space.xxl)
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Sign in with email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showReset) {
                PasswordResetRequestView(email: email)
                    .environmentObject(session)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func submit() {
        working = true
        error = nil
        Task {
            error = await session.signInWithEmail(email: email, password: password)
            working = false
            if error == nil { dismiss() }
        }
    }
}

// MARK: - Reset request

/// Two phases in one view. Phase 2 renders identically whether or not the address
/// exists — `sendPasswordReset` returns nil either way, so nothing here reveals
/// whether an account is registered.
struct PasswordResetRequestView: View {
    @EnvironmentObject private var session: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State var email: String
    @State private var code = ""
    @State private var sent = false
    @State private var error: SessionManager.EmailAuthError?
    @State private var working = false
    @State private var resendIn = 0

    /// @State, not `let`: a stored publisher would be rebuilt on every re-render
    /// (each keystroke in the code field) and the countdown would never fire.
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var canSend: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if let error {
                        ErrorBanner(message: error.message)
                    }
                    if sent { sentPhase } else { requestPhase }
                    Spacer(minLength: Space.xxl)
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(sent ? "Enter your code" : "Set or reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onReceive(tick) { _ in if resendIn > 0 { resendIn -= 1 } }
        }
        .navigationViewStyle(.stack)
    }

    private var requestPhase: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("We'll email you a verification code. Enter it on the next screen to choose a password.")
                .font(.bodyM)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            AuthField(
                title: "Email",
                placeholder: "you@example.com",
                text: $email,
                textContentType: .username,
                keyboard: .emailAddress,
                submitLabel: .send,
                onSubmit: { if canSend { send() } }
            )

            KButton(label: "Send code", loading: working, disabled: !canSend) { send() }
        }
    }

    private var sentPhase: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("If that address has an account, a code is on its way. Check your inbox and spam folder.")
                .font(.bodyM)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            AuthField(
                // Length is a server setting (Supabase allows 6–10), so never name
                // a digit count here — only gate on the shortest it can be.
                title: "Verification code",
                placeholder: "Code from the email",
                text: $code,
                keyboard: .numberPad,
                submitLabel: .go,
                onSubmit: { redeem() }
            )

            KButton(label: "Continue", loading: working, disabled: code.count < 6) { redeem() }

            VStack(alignment: .leading, spacing: Space.sm) {
                // The emailed link is PKCE-bound to the device that asked for it.
                Text("The email also has a link. It only works on this iPhone — the code works anywhere.")
                    .font(.caption)
                    .foregroundColor(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                KButton(
                    label: resendIn > 0 ? "Send again in \(resendIn)s" : "Send again",
                    variant: .ghost,
                    disabled: resendIn > 0 || working
                ) { send() }
            }
        }
    }

    private func send() {
        working = true
        error = nil
        Task {
            error = await session.sendPasswordReset(to: email)
            working = false
            if error == nil {
                sent = true
                resendIn = 60
            }
        }
    }

    private func redeem() {
        working = true
        error = nil
        Task {
            error = await session.redeemRecoveryCode(email: email, code: code)
            working = false
            // On success SessionManager moves to .mustSetPassword and RootView
            // swaps the whole tree, which tears this sheet down.
        }
    }
}

// MARK: - Set password

/// Full-screen and non-dismissable: reached only from `.mustSetPassword`, where a
/// recovery session exists but no password is set yet. "Sign out" is the escape
/// hatch so nobody can get stuck here.
struct SetPasswordView: View {
    @EnvironmentObject private var session: SessionManager

    @State private var password = ""
    @State private var confirm = ""
    @State private var error: SessionManager.EmailAuthError?
    @State private var localError: String?
    @State private var working = false

    private static let minLength = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 44))
                    .foregroundColor(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.xxl)

                Text("Choose a password")
                    .font(.titleXL)
                    .foregroundColor(Theme.textPrimary)
                Text("At least \(Self.minLength) characters. You'll be able to sign in with your email and this password from now on — Discord still works too.")
                    .font(.bodyM)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let localError {
                    ErrorBanner(message: localError)
                } else if let error {
                    ErrorBanner(message: error.message)
                }

                AuthField(
                    title: "New password",
                    text: $password,
                    secure: true,
                    textContentType: .newPassword
                )
                AuthField(
                    title: "Confirm password",
                    text: $confirm,
                    secure: true,
                    textContentType: .newPassword,
                    submitLabel: .go,
                    onSubmit: submit
                )

                KButton(label: "Save password", loading: working) { submit() }

                Button("Sign out") { Task { await session.signOut() } }
                    .font(.bodyM)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.sm)

                Spacer(minLength: Space.xxl)
            }
            .padding()
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func submit() {
        localError = nil
        error = nil
        guard password.count >= Self.minLength else {
            localError = "Password must be at least \(Self.minLength) characters."
            return
        }
        guard password == confirm else {
            localError = "The two passwords don't match."
            return
        }
        working = true
        Task {
            error = await session.setNewPassword(password)
            working = false
        }
    }
}
