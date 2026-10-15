import Foundation
import StoreKit
import SwiftUI
import UIKit

/// Profile: who's signed in, the household and the people who share it, invitations,
/// BigTable Pro, settings, and the account itself. The sheet behind the avatar in every tab's
/// toolbar (the caller provides the NavigationStack).
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceOption.system.rawValue
    @AppStorage(SettingsKey.accentHex) private var accentHex = hexString(Brand.defaultAccentHex)

    @State private var invitations: HouseholdInvitationsResponse?
    @State private var showPaywall = false
    @State private var showTutorial = false
    @State private var joinedHouseholdName: String?
    @State private var showMembershipInfo = false
    @State private var confirmLeave = false
    @State private var confirmSignOut = false
    @State private var showDeleteAccount = false
    @State private var deleteConfirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var subscriptions: Subscriptions { Subscriptions.shared }

    var body: some View {
        BigTableScreen(title: "Profile") {
            accountCard
            membershipCard

            householdSection

            ProfileInvitationsCard(
                invitations: invitations,
                showsSent: model.isOrganizer,
                onChanged: { await loadInvitations() },
                onAccepted: { name in joinedHouseholdName = name }
            )

            proSection
            settingsSection
            recipesSection
            ProfileInviteFriendCard()
            helpSection
            accountActions

            Text("BigTable \(AppConfig.version)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
        .refreshable {
            await model.reload()
            await loadInvitations()
            await subscriptions.refresh()
        }
        .task {
            await loadInvitations()
            await model.refreshUsage()
            await subscriptions.refresh()
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showTutorial) { TutorialView {} }
        .sheet(isPresented: $showMembershipInfo) {
            ProfileJoinedHouseholdInfoView(householdName: model.householdName)
        }
        .sheet(item: Binding(
            get: { joinedHouseholdName.map(ProfileJoinedName.init) },
            set: { joinedHouseholdName = $0?.name }
        )) { joined in
            ProfileJoinedHouseholdInfoView(householdName: joined.name)
        }
        .alert("Leave household?", isPresented: $confirmLeave) {
            Button("Leave", role: .destructive) { Task { await leaveHousehold() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave \(model.householdName)? You'll go back to your own household, and may need to set it up again.")
        }
        .alert("Sign out of BigTable?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to sign in again to see your meal plans.")
        }
        .alert("Delete your account?", isPresented: $showDeleteAccount) {
            TextField("DELETE", text: $deleteConfirmation)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Delete Account", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) { deleteConfirmation = "" }
        } message: {
            Text("This permanently erases your household, recipes and account. It can't be undone. A BigTable Pro subscription is canceled separately in your Apple Account's subscriptions. Type DELETE to confirm.")
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

    private var isPro: Bool { subscriptions.isPro || model.usage?.isPro == true }

    private var accountCard: some View {
        Card {
            HStack(spacing: 14) {
                MemberAvatar(
                    name: displayName,
                    color: PersonColor.forIndex(0).color,
                    url: ProfileAvatar.url(for: model.me?.myMember?.avatarUrl),
                    size: 60
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(displayName).font(.title3.bold())
                        if isPro { ProBadge() }
                    }
                    if let email = model.session?.user.email, !email.isEmpty {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !model.householdName.isEmpty {
                        Label(model.householdName, systemImage: "house")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var membershipCard: some View {
        if !model.isOrganizer {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "person.2.fill", color: PersonColor.teal.color, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Member of \(model.householdName.isEmpty ? "a household" : model.householdName)")
                                .font(.headline)
                            Text("You share their meal plan, grocery list and recipes.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("What this means", systemImage: "info.circle") { showMembershipInfo = true }
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    ProfileSecondaryButton(title: "Leave Household", systemImage: "door.left.hand.open", role: .destructive) {
                        confirmLeave = true
                    }
                }
            }
        }
    }

    // MARK: Household

    private var joinedPeople: [HouseholdMember] {
        model.members.filter { !($0.linkedProfileId ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var householdSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Household")
            ProfileCard {
                NavigationLink {
                    HouseholdEditorView()
                } label: {
                    ProfileRow(
                        symbol: "house.fill",
                        color: Brand.recipeTile,
                        title: model.householdName.isEmpty ? "Household" : model.householdName,
                        detail: householdDetail
                    )
                }
                .buttonStyle(.plain)

                if model.isOrganizer {
                    ForEach(Array(joinedPeople.enumerated()), id: \.offset) { _, member in
                        if let profileID = member.linkedProfileId {
                            let color = model.color(forMember: member.name)
                            ProfileDivider()
                            NavigationLink {
                                ProfileJoinedMemberView(profileID: profileID, name: member.name, avatarURL: ProfileAvatar.url(for: member.avatarUrl), color: color)
                            } label: {
                                HStack(spacing: 14) {
                                    MemberAvatar(name: member.name, color: color, url: ProfileAvatar.url(for: member.avatarUrl), size: 34)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(member.name).font(.body)
                                        Text("Joined · Permissions")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if model.isOrganizer && AppConfig.socialEnabled {
                Text("To add someone with their own BigTable account, find them in Community and invite them to your household.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var householdDetail: String {
        let count = model.members.count
        let people = count == 1 ? "1 person" : "\(count) people"
        return model.canEditMembers || model.isOrganizer ? "\(people) · Names, ages, likes and restrictions" : people
    }

    // MARK: Pro

    private var proSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("BigTable Pro")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "sparkles", color: PersonColor.purple.color, size: 40, filled: isPro)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isPro ? "Pro" : "Starter").font(.headline)
                            Text(proSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    if let usage = model.usage {
                        usageView(usage)
                    }
                    if model.isOrganizer {
                        if subscriptions.isPro {
                            ProfileSecondaryButton(title: "Manage Subscription", systemImage: "slider.horizontal.3") {
                                openURL(subscriptions.managementURL ?? ProfileLinks.manageSubscriptions)
                            }
                        } else {
                            Button {
                                showPaywall = true
                            } label: {
                                Label("See Plans", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            ProfileSecondaryButton(title: "Restore Purchases", systemImage: "arrow.clockwise") {
                                Task { await restore() }
                            }
                        }
                    }
                }
            }
        }
    }

    private var proSummary: String {
        if !model.isOrganizer {
            return isPro
                ? "Pro comes with \(model.householdName.isEmpty ? "your household" : model.householdName)."
                : "The household's organizer manages its plan."
        }
        if subscriptions.isPro, let date = subscriptions.expirationDate {
            let day = date.formatted(date: .abbreviated, time: .omitted)
            return subscriptions.willRenew ? "Renews \(day)." : "Ends \(day)."
        }
        return isPro
            ? "AI meal plans, AI grocery lists, recipe scanning and imports are on."
            : "Add AI meal plans and grocery lists, recipe scanning and imports from the web."
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
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Settings")
            ProfileCard {
                NavigationLink {
                    NotificationSettingsView()
                } label: {
                    ProfileRow(symbol: "bell.fill", color: Brand.allergy, title: "Notifications")
                }
                .buttonStyle(.plain)
                if AppConfig.socialEnabled {
                    ProfileDivider()
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        ProfileRow(symbol: "hand.raised.fill", color: PersonColor.blue.color, title: "Privacy", detail: "Community profile and blocked people")
                    }
                    .buttonStyle(.plain)
                }
                ProfileDivider()
                HStack(spacing: 14) {
                    IconTile(symbol: "circle.lefthalf.filled", color: PersonColor.indigo.color)
                    Text("Appearance")
                    Spacer(minLength: 8)
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceOption.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 56)
                ProfileDivider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        IconTile(symbol: "paintpalette.fill", color: Color(hexString: accentHex) ?? Brand.defaultAccent)
                        Text("Accent Color")
                    }
                    HStack(spacing: 10) {
                        ForEach(Brand.accents, id: \.hex) { choice in
                            accentSwatch(choice)
                        }
                    }
                    .padding(.leading, 48)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func accentSwatch(_ choice: AccentChoice) -> some View {
        let selected = accentHex.uppercased() == hexString(choice.hex).uppercased()
        return Button {
            accentHex = hexString(choice.hex)
        } label: {
            Circle()
                .fill(Color(hex: choice.hex))
                .frame(width: 32, height: 32)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.25 : 0), lineWidth: 2).padding(-4))
                .frame(minWidth: 40, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Recipes, help

    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Recipes")
            ProfileCard {
                NavigationLink {
                    ManageTagsView()
                } label: {
                    ProfileRow(symbol: "tag.fill", color: PersonColor.green.color, title: "Manage Tags")
                }
                .buttonStyle(.plain)
                ProfileDivider()
                NavigationLink {
                    DeletedRecipesView()
                } label: {
                    ProfileRow(symbol: "trash.fill", color: Color(hex: 0x8E8E93), title: "Deleted Recipes")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Help")
            ProfileCard {
                Button {
                    showTutorial = true
                } label: {
                    ProfileRow(symbol: "play.fill", color: PersonColor.orange.color, title: "Take the Tour", showsChevron: false)
                }
                .buttonStyle(.plain)
                ProfileDivider()
                Button {
                    requestReview()
                } label: {
                    ProfileRow(symbol: "star.fill", color: Color(hex: 0xC77700), title: "Rate BigTable", showsChevron: false)
                }
                .buttonStyle(.plain)
                if let mail = ProfileLinks.feedbackMail {
                    ProfileDivider()
                    Button {
                        openURL(mail)
                    } label: {
                        ProfileRow(symbol: "envelope.fill", color: PersonColor.blue.color, title: "Send Feedback", showsChevron: false)
                    }
                    .buttonStyle(.plain)
                }
                ProfileDivider()
                linkRow("Support", symbol: "questionmark.circle.fill", url: ProfileLinks.support)
                ProfileDivider()
                linkRow("Privacy Policy", symbol: "hand.raised.fill", url: ProfileLinks.privacy)
                ProfileDivider()
                linkRow("Terms of Use", symbol: "doc.text.fill", url: ProfileLinks.terms)
            }
        }
    }

    private func linkRow(_ title: String, symbol: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            ProfileRow(symbol: symbol, color: Color(hex: 0x6C6C70), title: title, showsChevron: false, trailingText: nil)
                .overlay(alignment: .trailing) {
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 16)
                        .accessibilityHidden(true)
                }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens in Safari")
    }

    private var accountActions: some View {
        ProfileCard {
            Button {
                confirmSignOut = true
            } label: {
                ProfileRow(symbol: "rectangle.portrait.and.arrow.right", color: Color(hex: 0x6C6C70), title: "Sign Out", showsChevron: false)
            }
            .buttonStyle(.plain)
            ProfileDivider()
            Button {
                deleteConfirmation = ""
                showDeleteAccount = true
            } label: {
                ProfileRow(symbol: "trash", color: Brand.allergy, title: "Delete Account", showsChevron: false, isDestructive: true)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Actions

    private func loadInvitations() async {
        invitations = try? await model.api.householdInvitations()
    }

    private func restore() async {
        isWorking = true
        defer { isWorking = false }
        await subscriptions.restore()
        if let message = subscriptions.lastError {
            subscriptions.lastError = nil
            errorMessage = message
        }
    }

    private func leaveHousehold() async {
        guard let userID = model.userID else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await model.api.removeHouseholdMember(userID)
            await model.reload()
            await loadInvitations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The household someone just joined, as a sheet item.
private struct ProfileJoinedName: Identifiable {
    var name: String
    var id: String { name }
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
            errorMessage = error.localizedDescription
        }
    }
}
