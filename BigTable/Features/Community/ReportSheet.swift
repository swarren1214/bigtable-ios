import SwiftUI

/// What's being reported (`kind` in `POST /v1/reports`).
nonisolated enum ReportKind: String, Sendable {
    case recipe, profile

    var noun: String { self == .recipe ? "recipe" : "profile" }
    var title: String { self == .recipe ? "Report Recipe" : "Report Profile" }
}

/// Why it's being reported (`reason` in `POST /v1/reports`), the same list in every Hearth app.
nonisolated enum ReportReason: String, CaseIterable, Identifiable, Sendable {
    case spam
    case harassment
    case hate
    case sexual
    case violence
    case selfHarm = "self_harm"
    case other

    /// The longest `details` the server takes.
    static let detailsLimit = 1000

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spam: "Spam"
        case .harassment: "Harassment or bullying"
        case .hate: "Hate"
        case .sexual: "Sexual content"
        case .violence: "Violence or threats"
        case .selfHarm: "Self-harm"
        case .other: "Something else"
        }
    }
}

/// A recipe or profile to report, as a sheet item.
nonisolated struct ReportTarget: Identifiable, Hashable, Sendable {
    var kind: ReportKind
    var targetID: String
    var id: String { "\(kind.rawValue)-\(targetID)" }
}

/// The "Report…" sheet for a published recipe or a public profile: a reason, optional details,
/// and Send. Errors show inline; a sent report shows a short thank-you and closes the sheet.
struct ReportSheet: View {
    var target: ReportTarget

    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $reason) {
                        ForEach(ReportReason.allCases) { option in
                            Text(option.label).tag(Optional(option))
                        }
                    } label: {
                        Text("Reason")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Why are you reporting this \(target.kind.noun)?")
                }

                Section {
                    TextField("Add details (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: details) { _, new in
                            if new.count > ReportReason.detailsLimit {
                                details = String(new.prefix(ReportReason.detailsLimit))
                            }
                        }
                } header: {
                    Text("Details")
                } footer: {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(target.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        SheetDoneButton("Send") { Task { await send() } }
                            .disabled(reason == nil)
                    }
                }
            }
            .disabled(isSending)
            .alert("Report sent", isPresented: $sent) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("Thanks. We review every report within 24 hours.")
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSending)
    }

    private func send() async {
        guard let reason, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await BigTableAPI.shared.report(target.kind, targetID: target.targetID, reason: reason, details: details)
            sent = true
        } catch is CancellationError {
            return
        } catch let error as APIError where error.status == 429 {
            errorMessage = "You've sent a lot of reports today. Try again tomorrow."
        } catch let error as APIError where error.kind == .signedOut {
            errorMessage = "Sign in to BigTable to send a report."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
