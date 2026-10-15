import Foundation
import SwiftUI
import UIKit

/// The first run after signing in, before there's a household: set one up (its name, the
/// people at the table, anything they can't eat) or join someone else's by accepting their
/// invitation.
struct HouseholdSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var step: AccountSetupStep = .intent
    @State private var isJoining = false
    @State private var draft = HouseholdDraft()
    @State private var hasStarted = false
    @State private var editing: ProfileMemberDraft?
    @State private var isNewMember = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmSignOut = false
    @State private var invitations: HouseholdInvitationsResponse?
    @State private var isCheckingInvitations = false

    var body: some View {
        Group {
            switch step {
            case .intent: intentPage
            case .join: joinPage
            case .name: namePage
            case .people: peoplePage
            case .dietary: dietaryPage
            }
        }
        .animation(.smooth, value: step)
        .sheet(item: $editing) { member in
            MemberEditorView(
                member: member,
                title: isNewMember ? "New Person" : member.displayName,
                color: color(for: member),
                canEdit: true,
                onSave: { updated in apply(updated) },
                onRemove: removeAction(for: member)
            )
        }
        .errorAlert($errorMessage)
        .alert("Sign out of BigTable?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear(perform: start)
    }

    // MARK: Steps

    private var intentPage: some View {
        OnboardingPage(
            title: "Welcome to BigTable",
            subtitle: "How would you like to get started?"
        ) { _ in
            AppIconBadge()
        } content: { _ in
            VStack(spacing: 12) {
                AccountIntentCard(
                    symbol: "house.fill",
                    title: "Set up my household",
                    detail: "Add the people you cook for. You can invite family to join later."
                ) {
                    isJoining = false
                    step = .name
                }
                AccountIntentCard(
                    symbol: "person.2.fill",
                    title: "Join a household",
                    detail: "Someone in your family already uses BigTable and will invite you."
                ) {
                    isJoining = true
                    step = .join
                    Task { await loadInvitations() }
                }
            }
        } controls: { _ in
            signOutButton
        }
    }

    private var joinPage: some View {
        OnboardingPage(
            title: "Join a household",
            subtitle: "The household's organizer invites you from BigTable. Your invitation shows up here."
        ) { _ in
            OnboardingSymbolIcon(symbol: "envelope.open.fill")
        } content: { _ in
            VStack(alignment: .leading, spacing: 16) {
                ProfileInvitationsCard(
                    invitations: invitations,
                    showsSent: false,
                    onChanged: { await loadInvitations() }
                )
                if pendingReceived.isEmpty {
                    if isCheckingInvitations && invitations == nil {
                        LoadingCard(title: "Checking for invitations…")
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            OnboardingFeatureRow(symbol: "person.crop.circle", title: "Set up your profile", detail: "So the organizer can find you in Community. Your name and photo are enough.")
                            OnboardingFeatureRow(symbol: "magnifyingglass", title: "They find you and invite you", detail: "In Community, on your profile, they tap Invite to Household.")
                            OnboardingFeatureRow(symbol: "checkmark.circle", title: "Accept here or in Profile", detail: "You'll share their meal plan and grocery list.")
                        }
                        .padding(.top, 4)
                    }
                }
            }
        } controls: { _ in
            VStack(spacing: 12) {
                OnboardingPrimaryButton(title: "Set Up My Profile") {
                    isJoining = true
                    step = .name
                }
                HStack(spacing: 12) {
                    Button {
                        Task { await loadInvitations() }
                    } label: {
                        Label(isCheckingInvitations ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(isCheckingInvitations)
                    backButton(to: .intent)
                }
            }
        }
    }

    private var namePage: some View {
        OnboardingPage(
            title: isJoining ? "Your household name" : "Name your household",
            subtitle: isJoining
                ? "It's how you show up in Community until you join a household."
                : "It's how your family shows up in BigTable.",
            step: (number: 1, of: 3)
        ) { isShort in
            OnboardingSymbolIcon(symbol: "house.fill", size: isShort ? 64 : 80)
        } content: { _ in
            TextField("The Carter Family", text: $draft.name)
                .font(.title3.weight(.semibold))
                .textInputAutocapitalization(.words)
                .submitLabel(.next)
                .onSubmit { if canLeaveName { step = .people } }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
        } controls: { _ in
            VStack(spacing: 12) {
                OnboardingPrimaryButton(title: "Continue") { step = .people }
                    .disabled(!canLeaveName)
                backButton(to: isJoining ? .join : .intent)
            }
        }
    }

    private var peoplePage: some View {
        OnboardingPage(
            title: isJoining ? "About you" : "Who's at the table?",
            subtitle: isJoining
                ? "Add your name and a photo. Your date of birth helps size portions."
                : "Add everyone you cook for, starting with you. Tap someone for their age, likes and dislikes.",
            step: (number: 2, of: 3)
        ) { isShort in
            OnboardingSymbolIcon(symbol: "person.2.fill", size: isShort ? 64 : 80)
        } content: { _ in
            VStack(spacing: 12) {
                CardList(items: draft.members, inset: 74) { member in
                    Button {
                        isNewMember = false
                        editing = member
                    } label: {
                        ProfileMemberRow(member: member, color: color(for: member), role: draft.members.first?.id == member.id ? "You" : member.ageLabel)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edits their details")
                }
                if !isJoining && draft.members.count < HouseholdDraft.maxMembers {
                    Button {
                        isNewMember = true
                        editing = ProfileMemberDraft()
                    } label: {
                        Label("Add Person", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
        } controls: { _ in
            VStack(spacing: 12) {
                OnboardingPrimaryButton(title: "Continue") { step = .dietary }
                    .disabled(draft.members.first?.trimmedName.isEmpty != false)
                backButton(to: .name)
            }
        }
    }

    private var dietaryPage: some View {
        OnboardingPage(
            title: "Anything to avoid?",
            subtitle: "Pick any dietary needs. BigTable keeps them out of the recipes it suggests.",
            step: (number: 3, of: 3)
        ) { isShort in
            OnboardingSymbolIcon(symbol: "leaf.fill", size: isShort ? 64 : 80)
        } content: { _ in
            VStack(alignment: .leading, spacing: 22) {
                ForEach($draft.members) { $member in
                    if !member.trimmedName.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                MemberAvatar(name: member.displayName, color: color(for: member), url: member.avatarURL, size: 30)
                                Text(member.displayName).font(.headline)
                            }
                            FlowLayout(spacing: 8) {
                                ForEach(HouseholdDraft.dietaryOptions, id: \.self) { option in
                                    ProfileOptionChip(title: option, isOn: member.restrictions.contains(option)) {
                                        if let index = member.restrictions.firstIndex(of: option) {
                                            member.restrictions.remove(at: index)
                                        } else {
                                            member.restrictions.append(option)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } controls: { _ in
            VStack(spacing: 12) {
                AccountBusyButton(title: "Start Planning", busyTitle: "Saving…", isBusy: isSaving) {
                    Task { await save() }
                }
                backButton(to: .people)
                    .disabled(isSaving)
            }
        }
    }

    // MARK: Pieces

    private var signOutButton: some View {
        Button("Sign Out") { confirmSignOut = true }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
    }

    private func backButton(to destination: AccountSetupStep) -> some View {
        Button {
            step = destination
        } label: {
            Text("Back").frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    private var canLeaveName: Bool {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= HouseholdDraft.maxNameLength
    }

    private var pendingReceived: [HouseholdInvitation] {
        (invitations?.received ?? []).filter { $0.status == .pending }
    }

    private func color(for member: ProfileMemberDraft) -> Color {
        PersonColor.forIndex(draft.members.firstIndex { $0.id == member.id } ?? 0).color
    }

    // MARK: Actions

    /// Starts from whatever the account already has (a half-finished setup), or with the
    /// name from sign-up or Apple as the first person.
    private func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if let me = model.me, !me.householdMembers.isEmpty {
            draft = HouseholdDraft(me: me, householdName: me.profile?.householdName ?? "", organizerProfileID: model.userID)
        } else {
            draft = HouseholdDraft(firstName: model.session?.user.fullName ?? "")
            draft.name = model.me?.profile?.householdName ?? ""
        }
        if (model.me?.membership?.pendingInvitationCount ?? 0) > 0 {
            Task { await loadInvitations() }
        }
    }

    /// Anyone but the first person (you) can be taken out again.
    private func removeAction(for member: ProfileMemberDraft) -> (() -> Void)? {
        guard draft.members.first?.id != member.id, draft.members.contains(where: { $0.id == member.id }) else { return nil }
        return { draft.members.removeAll { $0.id == member.id } }
    }

    private func apply(_ updated: ProfileMemberDraft) {
        if let index = draft.members.firstIndex(where: { $0.id == updated.id }) {
            draft.members[index] = updated
        } else if !updated.trimmedName.isEmpty {
            draft.members.append(updated)
        }
    }

    private func loadInvitations() async {
        isCheckingInvitations = true
        defer { isCheckingInvitations = false }
        // Offline or failing: keep what was there; Check Again tries once more.
        if let fresh = try? await model.api.householdInvitations() {
            invitations = fresh
        }
    }

    private func save() async {
        guard !isSaving else { return }
        let payload: SaveHouseholdPayload
        do {
            payload = try draft.payload(isOrganizer: true, userID: model.userID, organizerProfileID: model.userID)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.saveHousehold(payload)
            await model.reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Where the first run is.
nonisolated enum AccountSetupStep: Hashable, Sendable {
    case intent, join, name, people, dietary
}

/// A big choice on the first screen: tinted symbol, title, a line, and a chevron.
private struct AccountIntentCard: View {
    var symbol: String
    var title: String
    var detail: String
    var action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconTile(symbol: symbol, color: accent, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
