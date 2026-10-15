import SwiftUI

/// The Community tab: families who share recipes on BigTable. Discover new cooks, see who you
/// follow and who follows you, follow or unfollow with one tap, and open anyone's profile for
/// their published recipes.
struct CommunityView: View {
    @Environment(AppModel.self) private var model
    @State private var store = CommunityStore.shared
    @State private var mode: FollowMode = .discover
    @State private var query = ""

    private static let modes: [FollowMode] = [.discover, .following, .followers]

    private var page: CommunityStore.Page { store.page(mode) }

    /// Blocked people are left out of every list (Profile › Privacy lists them for unblocking).
    private var profiles: [FollowProfile] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return page.profiles.filter { profile in
            if store.isBlocked(profile.profileId) { return false }
            guard !needle.isEmpty else { return true }
            return CommunityFormat.name(profile.profileName).lowercased().contains(needle)
        }
    }

    var body: some View {
        BigTableScreen(title: "Community") {
            Picker("Show", selection: $mode) {
                ForEach(Self.modes) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            content
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: searchPrompt)
        .refreshable {
            await store.loadBlocked()
            await store.load(mode)
        }
        .task(id: "\(model.userID ?? "")|\(mode.rawValue)") {
            store.prepare()
            if !store.blockedLoaded { await store.loadBlocked() }
            if !page.loaded || store.stale.contains(mode) { await store.load(mode) }
        }
        .onAppear {
            // Coming back from a profile, or from unblocking someone in Profile › Privacy.
            Task {
                if store.blockedLoaded { await store.loadBlocked() }
                if page.loaded, store.stale.contains(mode) { await store.load(mode) }
            }
        }
        .navigationDestination(for: CommunityProfileRoute.self) { route in
            PublicProfileView(profileID: route.id)
        }
        .bigTableToolbar()
        .errorAlert($store.errorMessage)
    }

    private var searchPrompt: String {
        switch mode {
        case .discover: "Search Discover"
        case .following: "Search Following"
        case .followers: "Search Followers"
        }
    }

    @ViewBuilder
    private var content: some View {
        if !page.loaded, let error = page.error {
            RetryCard(message: error) { Task { await store.load(mode) } }
        } else if !page.loaded {
            LoadingCard(title: "Loading people…")
        } else if page.profiles.isEmpty {
            emptyState
        } else if profiles.isEmpty {
            EmptyCard(symbol: "magnifyingglass", title: "No matching people", message: "Try a different name.")
        } else {
            CardList(items: profiles, inset: 72) { profile in
                CommunityProfileRow(profile: profile, mode: mode, store: store, isMe: profile.profileId == model.userID)
            }

            if page.hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(minHeight: 44)
                .onScrollVisibilityChange(threshold: 0.1) { visible in
                    if visible { Task { await store.loadMore(mode) } }
                }
                .onAppear {
                    // A short list never scrolls: load the next page as soon as it shows.
                    if profiles.count < 8 { Task { await store.loadMore(mode) } }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch mode {
        case .discover:
            EmptyCard(symbol: "person.2", title: "No one to discover yet", message: "Families who share recipes on BigTable will appear here.")
        case .following:
            EmptyCard(symbol: "person.badge.plus", title: "Not following anyone yet", message: "Follow cooks from Discover or from a recipe they shared.")
        case .followers:
            EmptyCard(symbol: "heart", title: "No followers yet", message: "Followers will appear here as people find your recipes.")
        }
    }
}

/// Someone in a Community list: their photo, name, when they joined (or since when you've
/// been connected), their recipe and follower counts, and Follow or Unfollow.
struct CommunityProfileRow: View {
    var profile: FollowProfile
    var mode: FollowMode
    var store: CommunityStore
    var isMe: Bool

    private var name: String { CommunityFormat.name(profile.profileName) }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: CommunityProfileRoute(id: profile.profileId)) {
                HStack(spacing: 12) {
                    MemberAvatar(name: name, color: PersonColor.forKey(profile.profileId).color, url: profile.avatarUrl, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.headline)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let stats {
                            Text(stats)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(name)'s profile")

            if isMe {
                Text("You")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if store.isBlocked(profile.profileId) {
                Label("Blocked", systemImage: "nosign")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                CommunityFollowButton(profileID: profile.profileId, name: name, store: store, compact: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String? {
        switch mode {
        case .discover:
            return CommunityFormat.joined(profile.joinedAt ?? profile.followedAt)
        case .following:
            return CommunityFormat.since(profile.followedAt).map { "Following since \($0)" }
        case .followers:
            return CommunityFormat.since(profile.followedAt).map { "Follows you since \($0)" }
        }
    }

    private var stats: String? {
        var parts: [String] = []
        if let recipes = profile.publishedRecipeCount { parts.append(CommunityFormat.count(recipes, "recipe", "recipes")) }
        if let followers = profile.followerCount { parts.append(CommunityFormat.count(followers, "follower", "followers")) }
        if let followingCount = profile.followingCount { parts.append("\(followingCount.formatted()) following") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Follow or Unfollow, changed right away and confirmed with the server.
struct CommunityFollowButton: View {
    var profileID: String
    var name: String
    var store: CommunityStore
    var compact = false
    var onChange: ((Bool) -> Void)? = nil

    private var isFollowing: Bool { store.isFollowing(profileID) }
    private var isBusy: Bool { store.followBusy.contains(profileID) }

    var body: some View {
        Group {
            if isFollowing {
                Button(action: toggle) { label }
                    .buttonStyle(.glass)
            } else {
                Button(action: toggle) { label }
                    .buttonStyle(.glassProminent)
            }
        }
        .disabled(isBusy)
        .accessibilityLabel(isFollowing ? "Unfollow \(name)" : "Follow \(name)")
    }

    private var label: some View {
        Label(isFollowing ? "Unfollow" : "Follow", systemImage: isFollowing ? "person.badge.minus" : "person.badge.plus")
            .labelStyle(.titleAndIcon)
            .font(compact ? .subheadline.weight(.semibold) : .headline)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 28 : 34)
    }

    private func toggle() {
        Task {
            if let now = await store.toggleFollow(profileID) {
                onChange?(now)
            }
        }
    }
}
