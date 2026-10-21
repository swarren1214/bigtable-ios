import AuthenticationServices
import Foundation
import SwiftUI
import UIKit

/// Profile: the Hearth account (Sign in with Apple, optional), the plan (BigTable Plus or
/// Hearth+) and AI usage, settings, and the account itself. The household is HearthKit's
/// Household row. The sheet behind the avatar in every tab's toolbar (the caller provides the
/// NavigationStack).
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceOption.system.rawValue

    @State private var mealTimesSummary = HearthMealTimes.current.summary
    @State private var confirmSignOut = false
    @State private var showDeleteAccount = false
    @State private var deleteConfirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    @State private var purchases = HearthPurchases.shared

    var body: some View {
        // The shared Hearth Profile (HearthProfile.swift), with BigTable's own sections in the
        // middle. BigTable syncs through the Hearth API and its kitchen, so there's no iCloud
        // Sync row.
        HearthProfileView(
            app: .bigtable,
            profile: model.isSignedIn ? accountProfile : nil,
            erase: erase
        ) {
            Section {
                accountSection
                    .hearthAccountSectionRow()
            }
        } settings: {
            bigTableSections
        } data: {
        } about: {
        }
        .refreshable {
            await model.reload()
            await model.refreshUsage()
            await purchases.refresh()
        }
        .task {
            await model.refreshUsage()
            await purchases.refresh()
        }
        .alert("Sign out of BigTable?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your kitchen, recipes and plan stay. Community and AI need you to sign in again.")
        }
        .alert("Delete your Hearth account?", isPresented: $showDeleteAccount) {
            TextField("DELETE", text: $deleteConfirmation)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Delete Account", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) { deleteConfirmation = "" }
        } message: {
            Text("This permanently deletes your Hearth account, the one every Hearth app uses, and everything stored with it on our servers, including your published recipes and community profile. You'll be signed out of every Hearth app. It can't be undone. A BigTable Plus or Hearth+ subscription is canceled separately in your Apple Account's subscriptions. Type DELETE to confirm.")
        }
        .errorAlert($errorMessage)
        .overlay {
            if isWorking {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView().controlSize(.large)
                }
            }
        }
        .disabled(isWorking)
    }

    // MARK: Account and membership

    private var displayName: String {
        let candidates = [model.session?.user.fullName, model.me?.myMember?.name, model.householdName]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "BigTable"
    }

    private var isPro: Bool { model.hasPro }

    /// "Hearth+" or "BigTable Plus", when there's a plan.
    private var planLabel: String? {
        if purchases.membership?.kind == .hearthPlus { return "Hearth+" }
        return isPro ? "BigTable Plus" : nil
    }

    /// Erase BigTable Data, for someone in their own kitchen. A member of another family's
    /// household clears it by leaving the household (Profile › Household), so they get no Erase row.
    private var erase: HearthProfileErase? {
        guard KitchenStore.shared.canErase else { return nil }
        let shared = HearthHouseholdStore.shared.people.count > 1
        return HearthProfileErase(
            app: .bigtable,
            message: "This deletes every recipe, meal plan, grocery list, tag and pantry item from this \(UIDevice.current.localizedModel) and your iCloud\(shared ? ", and from everyone in your household" : ""). Recipes you published, your favorites and your community profile stay; Delete Account removes those. Your Hearth account and household aren't affected. This can't be undone.",
            footer: "Your kitchen lives in your iCloud and is shared with your household's adults."
        ) {
            KitchenStore.shared.eraseEverything()
            await model.reload()
        }
    }

    /// Who's signed in (always with Apple).
    private var accountProfile: HearthAccountProfile {
        let user = model.session?.user
        return HearthAccountProfile(
            name: displayName,
            email: user?.email,
            detail: model.householdName.isEmpty ? nil : model.householdName,
            photoURL: ProfileAvatar.url(for: model.me?.myMember?.avatarUrl).flatMap { URL(string: $0) }
        )
    }

    /// The shared Hearth account section (HearthAccount.swift), on Profile › Hearth Account.
    private var accountSection: some View {
        HearthAccountSection(
            app: .bigtable,
            profile: model.isSignedIn ? accountProfile : nil,
            pitch: "Sign in with Apple for the Community, AI meal plans and grocery lists, and your household's plan. Your kitchen works either way."
        ) {
            AccountAppleSignInButton(label: .signIn) { message in errorMessage = message }
        } onSignOut: {
            confirmSignOut = true
        } onDeleteAccount: {
            deleteConfirmation = ""
            showDeleteAccount = true
        }
    }

    /// BigTable's own sections: AI requests, settings and recipes.
    @ViewBuilder
    private var bigTableSections: some View {
        if let usage = model.usage {
            Section {
                usageView(usage)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } header: {
                Text(planLabel ?? "Starter")
            } footer: {
                Text(proSummary)
            }
        }

        Section("BigTable") {
            if model.isSignedIn {
                NavigationLink {
                    NotificationSettingsView()
                } label: {
                    HearthProfileRow("Notifications", systemImage: "bell")
                }
            }
            if AppConfig.socialEnabled && model.isSignedIn {
                NavigationLink {
                    PrivacyView()
                } label: {
                    HearthProfileRow("Privacy", systemImage: "hand.raised", value: "Community")
                }
            }
            NavigationLink {
                MealTimesView(app: .bigtable)
            } label: {
                HearthProfileRow("Meal Times", systemImage: "clock", value: mealTimesSummary)
            }
            .onAppear { mealTimesSummary = HearthMealTimes.current.summary }
            Picker(selection: $appearance) {
                ForEach(AppearanceOption.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                Label {
                    Text("Appearance")
                } icon: {
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.primary)
                }
            }
            .pickerStyle(.menu)
        }
        .tint(.primary)

        Section("Recipes") {
            NavigationLink {
                ManageTagsView()
            } label: {
                HearthProfileRow("Manage Tags", systemImage: "tag")
            }
            NavigationLink {
                DeletedRecipesView()
            } label: {
                HearthProfileRow("Deleted Recipes", systemImage: "trash")
            }
        }
        .tint(.primary)

        if model.isSignedIn {
            Section {
                ProfileInviteFriendCard()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var proSummary: String {
        if let membership = purchases.membership {
            switch membership.source {
            case .household:
                return "\(planLabel ?? "Plus") comes with \(model.householdName.isEmpty ? "your household" : model.householdName)."
            case .familySharing:
                return "\(planLabel ?? "Plus") comes with Family Sharing."
            case .own:
                if let date = membership.expiresAt {
                    let day = date.formatted(date: .abbreviated, time: .omitted)
                    return membership.willRenew ? "Renews \(day)." : "Ends \(day)."
                }
                if membership.term == .lifetime { return "Yours for good." }
            }
        }
        if !model.isOrganizer {
            return isPro
                ? "Plus comes with \(model.householdName.isEmpty ? "your household" : model.householdName)."
                : "The household's organizer manages its plan."
        }
        return isPro
            ? "AI meal plans, AI grocery lists, recipe scanning and imports are on."
            : "Add AI meal plans and grocery lists, recipe scanning and unlimited imports from the web."
    }

    private func usageView(_ usage: UsageCheckResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if usage.isUnlimited {
                Label("Unlimited AI requests", systemImage: "bolt.fill")
                    .font(.subheadline.weight(.medium))
            } else {
                HStack {
                    Text("AI requests")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(usage.requestsUsed) of \(usage.requestsLimit) used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: Double(min(usage.requestsUsed, usage.requestsLimit)), total: Double(max(usage.requestsLimit, 1)))
                if let resets = ISODay.timestamp(usage.resetsAt) {
                    Text("Resets \(resets.formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    // MARK: Actions

    private func signOut() async {
        isWorking = true
        defer { isWorking = false }
        if AppConfig.pushEnabled { await ProfilePush.disableServerTokens() }
        await model.signOut()
    }

    private func deleteAccount() async {
        guard deleteConfirmation.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE" else {
            deleteConfirmation = ""
            errorMessage = "Type DELETE to confirm deleting your account."
            return
        }
        deleteConfirmation = ""
        isWorking = true
        defer { isWorking = false }
        if AppConfig.pushEnabled { await ProfilePush.disableServerTokens() }
        do {
            try await model.deleteAccount()
        } catch let error as APIError where error.status == 409 {
            // HOUSEHOLD_HAS_MEMBERS: the account is kept.
            errorMessage = "Remove everyone else from Profile › Household first, then try again."
        } catch {
            errorMessage = FriendlyError.message(error)
        }
    }
}

/// Invite a friend to BigTable by email (the API sends the invitation).
struct ProfileInviteFriendCard: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var isSending = false
    @State private var sentTo: String?
    @State private var errorMessage: String?

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var looksValid: Bool {
        let parts = trimmed.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !trimmed.contains(" ")
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(symbol: "heart.fill", color: Brand.allergy, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invite a friend").font(.headline)
                        Text("Enjoying BigTable? Send a friend a link to get started.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let sentTo {
                    Label("Invitation sent to \(sentTo).", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: 0x1E9E6A))
                    Button("Invite Someone Else") {
                        self.sentTo = nil
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(.primary)
                } else {
                    HStack(spacing: 10) {
                        TextField("friend@example.com", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.send)
                            .onSubmit { Task { await send() } }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12))
                        Button {
                            Task { await send() }
                        } label: {
                            if isSending {
                                ProgressView()
                            } else {
                                Text("Send")
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!looksValid || isSending)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Brand.allergy)
                    }
                }
            }
        }
    }

    private func send() async {
        guard looksValid, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await model.api.sendAppInvitation(email: trimmed)
            sentTo = trimmed
            email = ""
        } catch {
            errorMessage = FriendlyError.message(error)
        }
    }
}
