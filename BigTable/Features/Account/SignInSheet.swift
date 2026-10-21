import AuthenticationServices
import SwiftUI

/// Asks for Sign in with Apple when something needs the Hearth account (Community, AI, sharing
/// recipes): what it's for, the button, and Not Now. Everything else in BigTable works signed
/// out. `AppModel.requireSignIn` shows it.
struct SignInSheet: View {
    let reason: SignInReason

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: reason.systemImage)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 36)
            VStack(spacing: 8) {
                Text(reason.title)
                    .font(.title2.weight(.bold))
                Text(reason.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
            AccountAppleSignInButton(label: .signIn) { message in
                errorMessage = message
            } onSuccess: {
                dismiss()
            }
            Button("Not Now") { dismiss() }
                .font(.body.weight(.semibold))
                .tint(.primary)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .presentationDetents([.medium])
        .errorAlert($errorMessage)
        .onChange(of: model.isSignedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
    }
}

/// In place of a screen that needs the Hearth account (the Community tab, Plan with AI,
/// Notifications), when signed out. Signs in right here: it may itself be inside a sheet, where
/// another sheet can't open.
struct SignInPrompt: View {
    let reason: SignInReason
    @State private var errorMessage: String?

    var body: some View {
        ContentUnavailableView {
            Label(reason.title, systemImage: reason.systemImage)
        } description: {
            Text(reason.message)
        } actions: {
            AccountAppleSignInButton(label: .signIn) { message in
                errorMessage = message
            }
            .frame(maxWidth: 320)
        }
        .errorAlert($errorMessage)
    }
}
