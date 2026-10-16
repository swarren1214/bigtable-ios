import Foundation
import SwiftUI

/// Choosing a new password after opening a reset link from email. Shown over everything while
/// `AppModel.needsNewPassword` is set.
struct NewPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case password, confirmation }

    private var strongEnough: Bool { AccountPasswordStrength.score(password) >= AccountPasswordStrength.minimumToSubmit }
    private var matches: Bool { !confirmation.isEmpty && password == confirmation }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focus = .confirmation }
                    SecureField("Type it again", text: $confirmation)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .confirmation)
                        .submitLabel(.done)
                        .onSubmit { Task { await save() } }
                } header: {
                    Text("Choose a new password")
                } footer: {
                    if !confirmation.isEmpty && !matches {
                        Text("The passwords don't match yet.")
                            .foregroundStyle(Brand.allergy)
                    }
                }
                if !password.isEmpty {
                    Section {
                        AccountPasswordGauge(password: password)
                            .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("New Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { close() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        SheetDoneButton("Save") { Task { await save() } }
                            .disabled(!strongEnough || !matches)
                    }
                }
            }
            .onAppear { focus = .password }
            .errorAlert($errorMessage, title: "Couldn't change your password")
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        guard strongEnough, matches, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await AuthClient.shared.updatePassword(password)
            close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func close() {
        AppModel.shared.needsNewPassword = false
        dismiss()
    }
}
