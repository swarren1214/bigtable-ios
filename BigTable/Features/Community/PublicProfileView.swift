import SwiftUI
import UIKit

/// Someone's public profile: their photo and name, when they joined, followers and following,
/// Follow, and the recipes they've published. The More menu invites them to your household
/// (organizers), cancels a pending invitation, reports them, or blocks and unblocks them.
///
/// Callers push it or wrap it in a NavigationStack; recipes open by pushing their detail.
struct PublicProfileView: View {
    var profileID: String
    /// Shows a Close button, for when this is the root of a sheet.
    var showsCloseButton = false

    init(profileID: String, showsCloseButton: Bool = false) {
        self.profileID = profileID
        self.showsCloseButton = showsCloseButton
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var community = CommunityStore.shared
    @State private var detail: SocialProfileDetailResponse?
    @State private var loadError: String?
    @State private var followerCount = 0
    @State private var confirming: PublicProfileAction?
    @State private var working: String?
    @State private var notice: PublicProfileNotice?
    @State private var reporting: ReportTarget?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    private var isMe: Bool { profileID == model.userID }

    private var name: String {
        if isMe, let mine = model.me?.myMember?.name, !mine.trimmingCharacters(in: .whitespaces).isEmpty { return mine }
        return CommunityFormat.name(detail?.profile.profileName)
    }

    private var avatarURL: String? {
        if isMe, let mine = ProfileAvatar.url(for: model.me?.myMember?.avatarUrl) { return mine }
        return detail?.profile.avatarUrl
    }

    private var isBlocked: Bool { community.isBlocked(profileID) }
    /// They've joined your household.
    private var isJoinedMember: Bool { model.members.contains { $0.linkedProfileId == profileID } }
    /// They're the organizer of the household you joined.
    private var isMyOrganizer: Bool { !model.isOrganizer && model.membership?.organizerProfileId == profileID }
    private var hasHouseholdRelationship: Bool { isJoinedMember || isMyOrganizer }
    private var pendingInvitation: HouseholdInvitation? { community.pendingInvitation(for: profileID) }
    private var canInvite: Bool { model.isOrganizer && !isJoinedMember && !isBlocked && pendingInvitation == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let detail {
                    header(detail.profile)
                    recipes(detail.recipes)
                } else if let loadError {
                    RetryCard(message: loadError) { Task { await load() } }
                } else {
                    LoadingCard(title: "Loading profile…")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: BigTableScreen<EmptyView>.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(detail == nil ? "Profile" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .refreshable { await load() }
        .task(id: profileID) { await load() }
        .overlay {
            if let working {
                ProgressView(working)
                    .padding(24)
                    .glassEffect(in: .rect(cornerRadius: 22))
            }
        }
        .alert(
            confirming?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { action in
            Button(action.cancelLabel, role: .cancel) {}
            Button(action.confirmLabel, role: action.isDestructive ? ButtonRole.destructive : nil) {
                Task { await perform(action) }
            }
        } message: { action in
            Text(action.message(name: name))
        }
        .alert(
            notice?.title ?? "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
            presenting: notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .errorAlert($community.errorMessage)
        .sheet(item: $reporting) { target in
            ReportSheet(target: target)
        }
    }

    // MARK: - Header

    private func header(_ profile: PublicProfile) -> some View {
        Card(padding: 20) {
            VStack(spacing: 14) {
                MemberAvatar(name: name, color: PersonColor.forKey(profileID).color, url: avatarURL, size: 96)
                VStack(spacing: 4) {
                    Text(name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(CommunityFormat.joinedBigTable(profile.joinedAt) ?? "BigTable member")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if hasHouseholdRelationship {
                        TagLabel(text: isMyOrganizer ? "Your household organizer" : "In your household", color: PersonColor.forKey(profileID).color)
                            .padding(.top, 2)
                    }
                }

                HStack(spacing: 0) {
                    count(followerCount, followerCount == 1 ? "Follower" : "Followers")
                    Divider().frame(height: 32)
                    count(profile.followingCount, "Following")
                    Divider().frame(height: 32)
                    count(detail?.recipes.count ?? 0, (detail?.recipes.count ?? 0) == 1 ? "Recipe" : "Recipes")
                }

                if !isMe {
                    if isBlocked {
                        Label("You've blocked \(name)", systemImage: "nosign")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    } else {
                        CommunityFollowButton(profileID: profileID, name: name, store: community) { nowFollowing in
                            followerCount = max(0, followerCount + (nowFollowing ? 1 : -1))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.title3.bold().monospacedDigit())
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Recipes

    @ViewBuilder
    private func recipes(_ recipes: [PublicRecipe]) -> some View {
        SectionTitle("Published recipes")
        if recipes.isEmpty {
            EmptyCard(symbol: "fork.knife", title: "No published recipes", message: isMe ? "Recipes you publish appear here for everyone." : "\(name) hasn't published any recipes yet.")
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(recipes) { recipe in
                    NavigationLink {
                        RecipeDetailView(recipeID: recipe.id, versionID: nil, showsCloseButton: false)
                    } label: {
                        CommunityRecipeCard(recipe: recipe)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - More

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsCloseButton {
            ToolbarItem(placement: .cancellationAction) {
                SheetCancelButton("Close") { dismiss() }
            }
        }
        if !isMe, detail != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if isJoinedMember {
                        Label { Text("In your household") } icon: { Image.menuIcon("house") }
                    } else if let pendingInvitation {
                        Label { Text("Invite Pending") } icon: { Image.menuIcon("clock") }
                        Button("Cancel Invitation", menuIcon: "xmark.circle", role: .destructive) {
                            confirming = .cancelInvitation(pendingInvitation)
                        }
                    }
                    // Family joins through the Hearth household now (Profile › Household ›
                    // Invite), which shares the kitchen and the plan.
                    Divider()
                    Button("Report…", menuIcon: "flag") {
                        reporting = ReportTarget(kind: .profile, targetID: profileID)
                    }
                    if isBlocked {
                        Button("Unblock \(name)", menuIcon: "person.crop.circle.badge.checkmark") {
                            confirming = .unblock
                        }
                    } else {
                        Button("Block \(name)", menuIcon: "nosign", role: .destructive) {
                            if hasHouseholdRelationship {
                                notice = PublicProfileNotice(
                                    title: "Can't block a household member",
                                    message: "You can't block someone while they're a member of your household or you're a member of theirs."
                                )
                            } else {
                                confirming = .block
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        community.prepare()
        do {
            let response = try await BigTableAPI.shared.publicProfile(profileID)
            detail = response
            followerCount = response.profile.followerCount
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            if detail == nil {
                loadError = "We couldn't load this profile right now. \(error.localizedDescription)"
            } else {
                community.errorMessage = error.localizedDescription
            }
        }
        if !community.blockedLoaded { await community.loadBlocked() }
        if model.isOrganizer { await community.loadInvitations() }
        if !isMe { await community.resolveFollowing(profileID) }
    }

    private func perform(_ action: PublicProfileAction) async {
        let name = self.name
        switch action {
        case .invite:
            working = "Sending invitation…"
            defer { working = nil }
            do {
                try await community.invite(profileID)
                notice = PublicProfileNotice(title: "Invitation sent", message: "\(name) has been invited to join your household.")
            } catch {
                notice = PublicProfileNotice(title: "Couldn't send the invitation", message: error.localizedDescription)
            }
        case .cancelInvitation(let invitation):
            working = "Cancelling invitation…"
            defer { working = nil }
            do {
                try await community.cancelInvitation(invitation)
                notice = PublicProfileNotice(title: "Invitation cancelled", message: "Your household invitation to \(name) has been cancelled.")
            } catch {
                notice = PublicProfileNotice(title: "Couldn't cancel the invitation", message: error.localizedDescription)
            }
        case .block:
            working = "Blocking…"
            defer { working = nil }
            do {
                try await community.block(profileID)
                dismiss()
            } catch {
                community.errorMessage = error.localizedDescription
            }
        case .unblock:
            working = "Unblocking…"
            defer { working = nil }
            do {
                try await community.unblock(profileID)
            } catch {
                community.errorMessage = error.localizedDescription
            }
        }
    }
}

/// What the More menu is asking to confirm.
enum PublicProfileAction: Identifiable {
    case invite
    case cancelInvitation(HouseholdInvitation)
    case block
    case unblock

    var id: String {
        switch self {
        case .invite: "invite"
        case .cancelInvitation(let invitation): "cancel-\(invitation.id)"
        case .block: "block"
        case .unblock: "unblock"
        }
    }

    var title: String {
        switch self {
        case .invite: "Invite to household?"
        case .cancelInvitation: "Cancel invitation?"
        case .block: "Block this person?"
        case .unblock: "Unblock this person?"
        }
    }

    func message(name: String) -> String {
        switch self {
        case .invite: "Invite \(name) to join your household? They'll be able to see your meal plan and grocery list."
        case .cancelInvitation: "Cancel your household invitation to \(name)?"
        case .block: "If you block \(name), they won't be able to view your profile or follow you. You can unblock them later in Profile › Privacy."
        case .unblock: "If you unblock \(name), they can view your profile and follow you again."
        }
    }

    var confirmLabel: String {
        switch self {
        case .invite: "Invite"
        case .cancelInvitation: "Cancel Invitation"
        case .block: "Block"
        case .unblock: "Unblock"
        }
    }

    var cancelLabel: String {
        if case .cancelInvitation = self { return "Keep" }
        return "Cancel"
    }

    var isDestructive: Bool {
        switch self {
        case .cancelInvitation, .block: true
        case .invite, .unblock: false
        }
    }
}

/// A short message after an action ("Invitation sent").
struct PublicProfileNotice: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// One of someone's published recipes: photo, title, likes and when it was published.
struct CommunityRecipeCard: View {
    var recipe: PublicRecipe

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecipePhoto(url: recipe.imageUrl, cornerRadius: 0)
                .frame(height: 120)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 10) {
                    Label(recipe.likeCount.formatted(), systemImage: "heart.fill")
                        .foregroundStyle(Brand.allergy)
                    if let published = CommunityFormat.since(recipe.publishedAt) {
                        Text(published)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recipe.title), \(recipe.likeCount) likes")
    }
}
