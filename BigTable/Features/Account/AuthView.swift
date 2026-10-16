import AuthenticationServices
import Foundation
import SwiftUI
import UIKit

/// Signing in. Sign in with Apple is the way in, as in every Hearth app (one sign-in for
/// BigTable, Sated and Suffice). Accounts made with an email and password before that can still
/// sign in (and reset a password) from a small link, and are then asked to add Apple
/// (`AppleLinkView`); new accounts can't be made with an email.
struct AuthView: View {
    @State private var path: [AccountAuthRoute] = []
    @State private var email = ""

    var body: some View {
        NavigationStack(path: $path) {
            AccountWelcomePage(path: $path)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: AccountAuthRoute.self) { route in
                    switch route {
                    case .signIn:
                        AccountSignInPage(email: $email, path: $path)
                    case .forgotPassword:
                        AccountForgotPasswordPage(email: $email, path: $path)
                    }
                }
        }
    }
}

/// The screens after Welcome.
nonisolated enum AccountAuthRoute: Hashable, Sendable {
    case signIn, forgotPassword
}

// MARK: - Welcome

/// The first screen: the app, what it does, and Sign in with Apple.
private struct AccountWelcomePage: View {
    @Binding var path: [AccountAuthRoute]
    @State private var errorMessage: String?

    var body: some View {
        OnboardingPage(
            title: "BigTable",
            subtitle: "Meal planning and grocery lists for big families."
        ) { _ in
            AppIconBadge()
        } content: { isShort in
            VStack(alignment: .leading, spacing: isShort ? 16 : 24) {
                OnboardingFeatureRow(symbol: "calendar", title: "Plan the week together", detail: "Breakfast, lunch and dinner for everyone at the table.")
                OnboardingFeatureRow(symbol: "cart", title: "One grocery list", detail: "Built from the plan and sorted by aisle.")
                OnboardingFeatureRow(symbol: "person.2", title: "Made for big families", detail: "Ages, likes and allergies shape every suggestion.")
            }
        } controls: { _ in
            VStack(spacing: 10) {
                AccountAppleSignInButton(label: .continue) { errorMessage = $0 }
                Text("One sign-in for BigTable, Sated and Suffice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Signed up with an email? Sign in") { path.append(.signIn) }
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .errorAlert($errorMessage, title: "Couldn't sign in")
    }
}

// MARK: - Sign in

/// Email and password sign in, for accounts made that way before Sign in with Apple was the
/// only way in.
private struct AccountSignInPage: View {
    @Binding var email: String
    @Binding var path: [AccountAuthRoute]
    @State private var password = ""
    @State private var emailError: String?
    @State private var passwordError: String?
    @State private var message: String?
    @State private var isSigningIn = false
    @FocusState private var focus: AccountAuthField?

    var body: some View {
        OnboardingPage(
            title: "Welcome back",
            subtitle: "Sign in to the BigTable account you made with your email. Next, you'll add Sign in with Apple to it."
        ) { isShort in
            OnboardingSymbolIcon(symbol: "person.crop.circle", size: isShort ? 64 : 80)
        } content: { _ in
            VStack(alignment: .leading, spacing: 14) {
                AccountTextField(title: "Email", text: $email, error: emailError, kind: .email, focus: $focus, field: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                AccountTextField(title: "Password", text: $password, error: passwordError, kind: .password, focus: $focus, field: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await signIn() } }
                Button("Forgot password?") { path.append(.forgotPassword) }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                if let message {
                    AccountMessage(text: message, isError: true)
                }
            }
        } controls: { _ in
            VStack(spacing: 12) {
                AccountBusyButton(title: "Sign In", busyTitle: "Signing In…", isBusy: isSigningIn) {
                    Task { await signIn() }
                }
            }
        }
        .onChange(of: email) { _, _ in emailError = nil }
        .onChange(of: password) { _, _ in passwordError = nil }
    }

    private func signIn() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        emailError = AccountValidation.emailError(trimmed)
        passwordError = password.isEmpty ? "Enter your password." : nil
        guard emailError == nil, passwordError == nil, !isSigningIn else { return }
        focus = nil
        message = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await AuthClient.shared.signIn(email: trimmed, password: password)
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Forgot password

/// Sends a password reset link; the link opens the app to choose a new password.
private struct AccountForgotPasswordPage: View {
    @Binding var email: String
    @Binding var path: [AccountAuthRoute]
    @State private var emailError: String?
    @State private var message: String?
    @State private var isSending = false
    @State private var sentTo: String?

    var body: some View {
        OnboardingPage(
            title: sentTo == nil ? "Reset your password" : "Check your email",
            subtitle: sentTo.map { "We sent a reset link to \($0). Tap it on this \(DeviceName.current) to choose a new password." }
                ?? "Enter your account's email and we'll send you a link to reset your password."
        ) { isShort in
            OnboardingSymbolIcon(symbol: sentTo == nil ? "key.fill" : "envelope.fill", size: isShort ? 64 : 80)
        } content: { _ in
            VStack(alignment: .leading, spacing: 14) {
                if sentTo == nil {
                    AccountTextField(title: "Email", text: $email, error: emailError, kind: .email)
                        .submitLabel(.send)
                        .onSubmit { Task { await send() } }
                }
                if let message {
                    AccountMessage(text: message, isError: true)
                }
            }
        } controls: { _ in
            VStack(spacing: 12) {
                if sentTo == nil {
                    AccountBusyButton(title: "Send Reset Link", busyTitle: "Sending…", isBusy: isSending) {
                        Task { await send() }
                    }
                    .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    OnboardingPrimaryButton(title: "Back to Sign In") { path = [.signIn] }
                    Button {
                        Task { await send() }
                    } label: {
                        Text(isSending ? "Sending…" : "Send It Again").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(isSending)
                }
            }
        }
        .onChange(of: email) { _, _ in emailError = nil }
    }

    private func send() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        emailError = AccountValidation.emailError(trimmed)
        guard emailError == nil, !isSending else { return }
        message = nil
        isSending = true
        defer { isSending = false }
        do {
            try await AuthClient.shared.sendPasswordReset(email: trimmed)
            sentTo = trimmed
        } catch AuthError.rateLimited {
            message = "A reset email was sent recently. Check your inbox (and spam), or wait a few minutes and try again."
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Pieces

/// Which field has the keyboard.
nonisolated enum AccountAuthField: Hashable, Sendable {
    case name, email, password
}

/// A rounded text field for the account screens, with its problem underneath.
struct AccountTextField: View {
    enum Kind { case name, email, password, newPassword }

    var title: String
    @Binding var text: String
    var error: String?
    var kind: Kind
    var focus: FocusState<AccountAuthField?>.Binding? = nil
    var field: AccountAuthField? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                switch kind {
                case .name:
                    TextField(title, text: $text)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                case .email:
                    TextField(title, text: $text)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .password:
                    SecureField(title, text: $text)
                        .textContentType(.password)
                case .newPassword:
                    SecureField(title, text: $text)
                        .textContentType(.newPassword)
                }
            }
            .modifier(AccountFocusModifier(focus: focus, field: field))
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(error == nil ? Color.clear : Brand.allergy, lineWidth: 1.5))
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Brand.allergy)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Ties a field to the screen's keyboard focus, when the screen tracks it.
private struct AccountFocusModifier: ViewModifier {
    var focus: FocusState<AccountAuthField?>.Binding?
    var field: AccountAuthField?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let focus, let field {
            content.focused(focus, equals: field)
        } else {
            content
        }
    }
}

/// A message under the fields: what went wrong, or what happened.
struct AccountMessage: View {
    var text: String
    var isError: Bool

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(isError ? Brand.allergy : Color(hex: 0x1E9E6A))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((isError ? Brand.allergy : Color(hex: 0x1E9E6A)).opacity(0.1), in: .rect(cornerRadius: 14))
    }
}

/// The big accent button, with a spinner while it works.
struct AccountBusyButton: View {
    var title: String
    var busyTitle: String
    var isBusy: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isBusy { ProgressView().tint(.white) }
                Text(isBusy ? busyTitle : title)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(isBusy)
    }
}

/// The email checks the Expo app made before asking Supabase.
enum AccountValidation {
    static func emailError(_ email: String) -> String? {
        if email.isEmpty { return "Enter your email." }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !email.contains(where: \.isWhitespace) else {
            return "Enter a valid email address."
        }
        return nil
    }
}
