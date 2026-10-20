import AuthenticationServices
import Foundation
import SwiftUI
import UIKit

/// Signing in. Sign in with Apple is the only way in, as in every Hearth app (one sign-in for
/// BigTable, Sated and Suffice). Someone still signed in with an old email account is asked to
/// add Apple to it (`AppleLinkView`).
struct AuthView: View {
    var body: some View {
        AccountWelcomePage()
    }
}

// MARK: - Welcome

/// The first screen: the app, what it does, and Sign in with Apple.
private struct AccountWelcomePage: View {
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
            }
        }
        .errorAlert($errorMessage, title: "Couldn't sign in")
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
