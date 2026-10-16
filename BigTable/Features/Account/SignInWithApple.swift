import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI

/// Sign in with Apple, signing in to the same Supabase account the Expo app used. Each request
/// carries the SHA-256 of a fresh random nonce; the raw nonce goes to Supabase with Apple's
/// identity token, along with the name Apple shares the first time.
struct AccountAppleSignInButton: View {
    var label: SignInWithAppleButton.Label = .continue
    /// Adds Apple to the signed-in account (one made with an email) instead of signing in.
    var linksCurrentAccount = false
    var onError: (String) -> Void
    var onSuccess: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = ""
    @State private var isSigningIn = false

    var body: some View {
        SignInWithAppleButton(label) { request in
            let raw = AccountNonce.random()
            nonce = raw
            request.requestedScopes = [.fullName, .email]
            request.nonce = AccountNonce.sha256(raw)
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                finish(authorization)
            case .failure(let error):
                if let appleError = error as? ASAuthorizationError, appleError.code == .canceled { return }
                onError(error.localizedDescription)
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50)
        .clipShape(Capsule())
        .disabled(isSigningIn)
        .opacity(isSigningIn ? 0.6 : 1)
        .overlay {
            if isSigningIn { ProgressView() }
        }
    }

    private func finish(_ authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            onError("Apple didn't send back a sign-in token. Try again.")
            return
        }
        let parts: [String?] = [credential.fullName?.givenName, credential.fullName?.middleName, credential.fullName?.familyName]
        let fullName = parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let rawNonce = nonce
        let appleUserID = credential.user
        let appleEmail = credential.email
        // Apple sends the name only the first time, in whichever Hearth app asked first. That
        // app shared it, so a later sign-in here can still use it.
        let sharedName = ScreenshotMode.isOn ? nil : HearthAccounts.appleID()
            .flatMap { $0.userID == appleUserID ? $0.fullName : nil }
        isSigningIn = true
        Task {
            defer { isSigningIn = false }
            do {
                if linksCurrentAccount {
                    try await AuthClient.shared.linkApple(idToken: identityToken, nonce: rawNonce)
                } else {
                    try await AuthClient.shared.signInWithApple(
                        idToken: identityToken,
                        nonce: rawNonce,
                        fullName: fullName.isEmpty ? nil : fullName,
                        fallbackName: sharedName
                    )
                }
                if !ScreenshotMode.isOn {
                    HearthAccounts.saveAppleID(HearthSharedAppleID(
                        userID: appleUserID,
                        fullName: fullName.isEmpty ? nil : fullName,
                        email: appleEmail,
                        updatedBy: .bigtable
                    ))
                }
                onSuccess()
            } catch {
                onError(Self.message(for: error))
            }
        }
    }

    /// Supabase's configuration errors, in words that say what to fix (as the Expo app did).
    private static func message(for error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("is not enabled") && text.lowercased().contains("apple") {
            return "Sign in with Apple isn't turned on for this BigTable server yet."
        }
        if text.contains("Unacceptable audience") {
            return "The server doesn't accept Sign in with Apple from this app yet (add com.stephenwarren.bigtable to Supabase's Apple client IDs)."
        }
        return text
    }
}

/// The nonce for Sign in with Apple.
enum AccountNonce {
    /// A random string from the system's secure generator.
    static func random(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        }
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    /// Lowercase hex SHA-256, what Apple puts in the token and Supabase checks.
    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
