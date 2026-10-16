import AuthenticationServices
import Foundation
import SwiftUI

/// Shown to someone signed in with an email and password: add Sign in with Apple to this
/// account. Email sign-in is going away (every Hearth app signs in with Apple), and adding Apple
/// keeps the account itself: recipes, household, plans and Pro stay as they are. "Not Now" asks
/// again in a few days.
struct AppleLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var errorMessage: String?
    @State private var linked = false

    var body: some View {
        OnboardingPage(
            title: linked ? "You're all set" : "Add Sign in with Apple",
            subtitle: linked
                ? "From now on, sign in to BigTable with Apple. Sated and Suffice will know you too."
                : "BigTable is moving to Sign in with Apple, like the other Hearth apps. Add it to your account now and everything stays: your recipes, household, plans and Pro."
        ) { isShort in
            OnboardingSymbolIcon(symbol: linked ? "checkmark.seal.fill" : "apple.logo", size: isShort ? 64 : 80)
        } content: { _ in
            VStack(alignment: .leading, spacing: 14) {
                if let email = model.session?.user.email, !linked {
                    Label("Signed in as \(email)", systemImage: "envelope")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    AccountMessage(text: errorMessage, isError: true)
                }
            }
        } controls: { _ in
            VStack(spacing: 10) {
                if linked {
                    OnboardingPrimaryButton(title: "Done") { dismiss() }
                } else {
                    AccountAppleSignInButton(label: .continue, linksCurrentAccount: true) {
                        errorMessage = $0
                    } onSuccess: {
                        withAnimation { linked = true }
                    }
                    Button("Not Now") {
                        AppleLinkPrompt.snooze()
                        dismiss()
                    }
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .interactiveDismissDisabled()
        .sensoryFeedback(.success, trigger: linked)
    }
}

/// When to ask an email account to add Apple: not again for three days after "Not Now".
enum AppleLinkPrompt {
    private static let key = "account.appleLinkSnoozedUntil"

    static var isSnoozed: Bool {
        UserDefaults.standard.double(forKey: key) > Date.now.timeIntervalSince1970
    }

    static func snooze(days: Double = 3) {
        UserDefaults.standard.set(Date.now.timeIntervalSince1970 + days * 86_400, forKey: key)
    }
}
