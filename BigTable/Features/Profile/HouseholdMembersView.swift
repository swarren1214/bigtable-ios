import Foundation
import SwiftUI

// People who share a household through their own accounts: what the organizer lets each of
// them do, removing them, and household invitations sent and received.

/// Someone who joined the organizer's household with their own account: what they're allowed
/// to do (manage the plan, edit people, and, with Pro, use AI), their Community profile, and
/// removing them.
struct ProfileJoinedMemberView: View {
    var profileID: String
    var name: String
    var avatarURL: String?
    var color: Color

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var permissions: HouseholdMemberPermissions?
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmRemove = false
    @State private var isRemoving = false
    @State private var showPaywall = false

    private var api: BigTableAPI { model.api }
    /// AI permissions need the organizer to have Pro (the API refuses them otherwise).
    private var organizerHasPro: Bool { Subscriptions.shared.isPro || model.usage?.isPro == true }

    var body: some View {
        BigTableScreen(title: name) {
            Card {
                HStack(spacing: 14) {
                    MemberAvatar(name: name, color: color, url: avatarURL, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.title3.bold())
                        Text("Joined with their own BigTable account")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SectionTitle("Permissions")
            if let permissions {
                permissionsCard(permissions)
            } else if let loadError {
                RetryCard(message: loadError) { Task { await load() } }
            } else {
                LoadingCard()
            }
            Text("They always see the household's meal plan, grocery list and recipes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ProfileCard {
                if AppConfig.socialEnabled {
                    NavigationLink {
                        PublicProfileView(profileID: profileID)
                    } label: {
                        ProfileRow(symbol: "person.crop.circle", color: color, title: "View Community Profile")
                    }
                    .buttonStyle(.plain)
                    ProfileDivider()
                }
                Button {
                    confirmRemove = true
                } label: {
                    ProfileRow(symbol: "person.crop.circle.badge.minus", color: Brand.allergy, title: "Remove from Household", showsChevron: false, isDestructive: true)
                }
                .buttonStyle(.plain)
                .disabled(isRemoving)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("Remove household member?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \(name) from your household? They'll go back to managing their own household.")
        }
        .errorAlert($errorMessage)
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .overlay {
            if isRemoving {
                ProgressView().controlSize(.large)
            }
        }
    }

    private func permissionsCard(_ current: HouseholdMemberPermissions) -> some View {
        ProfileCard {
            ProfileToggleRow(
                symbol: "calendar",
                color: MealSlotType.dinner.color,
                title: "Manage the meal plan",
                detail: "Add, change and remove meals, snacks and nights out.",
                isOn: binding(\.canManageMealPlan),
                isDisabled: isSaving
            )
            ProfileDivider()
            ProfileToggleRow(
                symbol: "person.2",
                color: PersonColor.teal.color,
                title: "Edit household members",
                detail: "Change other people's names, preferences and restrictions (not yours).",
                isOn: binding(\.canEditMembers),
                isDisabled: isSaving
            )
            ProfileDivider()
            ProfileToggleRow(
                symbol: "sparkles",
                color: PersonColor.purple.color,
                title: "AI meal planning",
                detail: "Plan a week of meals with AI.",
                isOn: binding(\.canUseAiMealPlan),
                isDisabled: isSaving || !organizerHasPro
            )
            ProfileDivider()
            ProfileToggleRow(
                symbol: "wand.and.stars",
                color: PersonColor.blue.color,
                title: "AI grocery lists",
                detail: "Build the grocery list with AI.",
                isOn: binding(\.canUseAiGrocery),
                isDisabled: isSaving || !organizerHasPro
            )
            if !organizerHasPro {
                ProfileDivider()
                Button {
                    showPaywall = true
                } label: {
                    ProfileRow(symbol: "sparkles", color: PersonColor.purple.color, title: "Upgrade to Pro to share AI", detail: "AI planning and grocery lists need BigTable Pro.")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Each switch saves on its own, and switches back if the API says no (its message, such
    /// as the Pro requirement, is shown).
    private func binding(_ keyPath: WritableKeyPath<HouseholdMemberPermissions, Bool>) -> Binding<Bool> {
        Binding(
            get: { permissions?[keyPath: keyPath] ?? false },
            set: { value in
                guard let previous = permissions else { return }
                var next = previous
                next[keyPath: keyPath] = value
                permissions = next
                Task { await save(next, previous: previous) }
            }
        )
    }

    private func load() async {
        loadError = nil
        do {
            permissions = try await api.memberPermissions(profileID)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save(_ next: HouseholdMemberPermissions, previous: HouseholdMemberPermissions) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.saveMemberPermissions(profileID, next)
        } catch {
            permissions = previous
            if let apiError = error as? APIError, apiError.isForbidden || apiError.isLimitReached, !organizerHasPro {
                showPaywall = true
            }
            errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        isRemoving = true
        defer { isRemoving = false }
        do {
            _ = try await api.removeHouseholdMember(profileID)
            await model.reload()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Household invitations waiting on an answer: ones this person received (Accept, Decline)
/// and, for an organizer, ones they sent (Cancel). Shows nothing when there are none.
struct ProfileInvitationsCard: View {
    var invitations: HouseholdInvitationsResponse?
    var showsSent = true
    /// Called after any answer, to load the invitations again.
    var onChanged: () async -> Void
    /// Called after accepting, with the household's name.
    var onAccepted: (String) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @State private var pending: ProfileInvitationAction?
    @State private var busyID: String?
    @State private var errorMessage: String?

    private var received: [HouseholdInvitation] {
        (invitations?.received ?? []).filter { $0.status == .pending }
    }

    private var sent: [HouseholdInvitation] {
        showsSent ? (invitations?.sent ?? []).filter { $0.status == .pending } : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !received.isEmpty {
                SectionTitle("Invitations")
                CardList(items: received, inset: 74) { invitation in
                    receivedRow(invitation)
                }
            }
            if !sent.isEmpty {
                SectionTitle("Waiting to join")
                CardList(items: sent, inset: 74) { invitation in
                    sentRow(invitation)
                }
            }
        }
        .alert(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
            Button(action.confirmLabel, role: action.isDestructive ? .destructive : nil) {
                Task { await perform(action) }
            }
            Button(action.cancelLabel, role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .errorAlert($errorMessage)
    }

    private func receivedRow(_ invitation: HouseholdInvitation) -> some View {
        let name = Self.name(invitation.organizer)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                MemberAvatar(name: name, color: PersonColor.forKey(invitation.organizerProfileId).color, url: ProfileAvatar.url(for: invitation.organizer?.avatarUrl), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(name) invited you to join their household")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(relativeTime(invitation.createdAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button {
                    pending = .accept(invitation, name)
                } label: {
                    Text("Accept").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glassProminent)
                Button {
                    pending = .decline(invitation, name)
                } label: {
                    Text("Decline").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glass)
            }
            .disabled(busyID != nil)
            .overlay {
                if busyID == invitation.id { ProgressView() }
            }
        }
        .padding(16)
    }

    private func sentRow(_ invitation: HouseholdInvitation) -> some View {
        let name = Self.name(invitation.invitee)
        return HStack(spacing: 14) {
            MemberAvatar(name: name, color: PersonColor.forKey(invitation.inviteeProfileId).color, url: ProfileAvatar.url(for: invitation.invitee?.avatarUrl), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text("Invited \(relativeTime(invitation.createdAt).lowercased())")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if busyID == invitation.id {
                ProgressView()
            } else {
                Button("Cancel") { pending = .cancel(invitation, name) }
                    .buttonStyle(.bordered)
                    .disabled(busyID != nil)
                    .accessibilityLabel("Cancel invitation to \(name)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private static func name(_ party: HouseholdInvitationParty?) -> String {
        let trimmed = (party?.profileName ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "A BigTable household" : trimmed
    }

    private func perform(_ action: ProfileInvitationAction) async {
        busyID = action.invitation.id
        defer { busyID = nil }
        do {
            switch action {
            case .accept(let invitation, let name):
                _ = try await model.api.respondToInvitation(invitation.id, accept: true)
                await model.reload()
                onAccepted(name)
            case .decline(let invitation, _):
                _ = try await model.api.respondToInvitation(invitation.id, accept: false)
            case .cancel(let invitation, _):
                _ = try await model.api.cancelInvitation(invitation.id)
            }
            await model.refreshUnreadCount()
        } catch let error as APIError where error.status == 404 {
            errorMessage = "This invitation is no longer available."
        } catch {
            errorMessage = error.localizedDescription
        }
        await onChanged()
    }
}

/// An answer to a household invitation, waiting on confirmation.
private enum ProfileInvitationAction {
    case accept(HouseholdInvitation, String)
    case decline(HouseholdInvitation, String)
    case cancel(HouseholdInvitation, String)

    var invitation: HouseholdInvitation {
        switch self {
        case .accept(let invitation, _), .decline(let invitation, _), .cancel(let invitation, _): invitation
        }
    }

    var title: String {
        switch self {
        case .accept: "Accept invitation?"
        case .decline: "Decline invitation?"
        case .cancel: "Cancel invitation?"
        }
    }

    var message: String {
        switch self {
        case .accept(_, let name): "Join \(name)? Your own household stays saved but hidden while you're a member."
        case .decline(_, let name): "Decline the invitation from \(name)?"
        case .cancel(_, let name): "Cancel your household invitation to \(name)?"
        }
    }

    var confirmLabel: String {
        switch self {
        case .accept: "Accept"
        case .decline: "Decline"
        case .cancel: "Cancel Invitation"
        }
    }

    var cancelLabel: String {
        switch self {
        case .cancel: "Keep"
        default: "Not Now"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .accept: false
        case .decline, .cancel: true
        }
    }
}

/// What joining someone else's household means, shown after accepting an invitation and from
/// the membership card.
struct ProfileJoinedHouseholdInfoView: View {
    var householdName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OnboardingPage(
            title: "You've joined \(householdName)",
            subtitle: "Here's what that means for your account."
        ) { _ in
            OnboardingSymbolIcon(symbol: "house.fill", size: 84)
        } content: { _ in
            VStack(alignment: .leading, spacing: 22) {
                OnboardingFeatureRow(symbol: "calendar", title: "You see their plan", detail: "The household's weekly meal plan, grocery list and recipes are yours to use.")
                OnboardingFeatureRow(symbol: "person.crop.circle", title: "Your own household is put away", detail: "It stays safely saved and comes back if you leave.")
                OnboardingFeatureRow(symbol: "lock", title: "The organizer decides what you can change", detail: "They can let you manage the plan, edit people or use AI.")
                OnboardingFeatureRow(symbol: "door.left.hand.open", title: "You can leave anytime", detail: "From Profile. The organizer can also remove you.")
            }
        } controls: { _ in
            OnboardingPrimaryButton(title: "Got It") { dismiss() }
        }
        .presentationDragIndicator(.visible)
    }
}
