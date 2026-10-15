import Foundation
import Observation
import OSLog

/// Community's people: who to discover, who you follow and who follows you (25 at a time),
/// who you follow (for every Follow button in the app), who you've blocked, and the household
/// invitations you've sent. Shared, so a profile opened from a notification or a recipe shows
/// the same follow state as the Community tab.
@MainActor
@Observable
final class CommunityStore {
    static let shared = CommunityStore()
    /// The Expo app's page size.
    static let pageSize = 25

    /// One list (Discover, Following or Followers) and how far it has loaded.
    struct Page {
        var profiles: [FollowProfile] = []
        var nextOffset = 0
        var hasMore = false
        var loaded = false
        var error: String?
    }

    private(set) var pages: [FollowMode: Page] = [:]
    private(set) var loading: Set<FollowMode> = []
    private(set) var loadingMore: Set<FollowMode> = []
    /// Lists that changed elsewhere (following someone new) and should reload when shown.
    private(set) var stale: Set<FollowMode> = []
    /// Who you follow, by profile id (from every list and every Follow tap).
    private(set) var following: [String: Bool] = [:]
    /// Follow taps waiting on the server.
    private(set) var followBusy: Set<String> = []
    private(set) var blocked: Set<String> = []
    private(set) var blockedLoaded = false
    /// Pending household invitations this person (an organizer) has sent.
    private(set) var sentInvitations: [HouseholdInvitation] = []
    var errorMessage: String?

    private let api = BigTableAPI.shared
    private var ownerID: String?
    private var followingResolved = false
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "community")

    /// Forgets everything when someone else signs in.
    func prepare() {
        let id = AppModel.shared.userID
        guard id != ownerID else { return }
        ownerID = id
        pages = [:]
        loading = []
        loadingMore = []
        stale = []
        following = [:]
        followBusy = []
        blocked = []
        blockedLoaded = false
        sentInvitations = []
        followingResolved = false
    }

    func page(_ mode: FollowMode) -> Page { pages[mode] ?? Page() }

    func isFollowing(_ profileID: String) -> Bool { following[profileID] ?? false }
    func isBlocked(_ profileID: String) -> Bool { blocked.contains(profileID) }

    func pendingInvitation(for profileID: String) -> HouseholdInvitation? {
        sentInvitations.first { $0.inviteeProfileId == profileID && $0.status == .pending }
    }

    // MARK: - Lists

    /// Loads the first page of a list, replacing what was there.
    func load(_ mode: FollowMode) async {
        prepare()
        guard !loading.contains(mode) else { return }
        loading.insert(mode)
        defer { loading.remove(mode) }
        do {
            let response = try await api.follows(mode, limit: Self.pageSize, offset: 0)
            var page = Page()
            page.profiles = dedupe(response.profiles)
            page.nextOffset = response.pagination?.nextOffset ?? response.profiles.count
            page.hasMore = response.pagination?.hasMore ?? false
            page.loaded = true
            pages[mode] = page
            stale.remove(mode)
            remember(response.profiles, mode: mode)
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("Couldn't load \(mode.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            var page = pages[mode] ?? Page()
            if page.loaded {
                errorMessage = error.localizedDescription
            } else {
                page.error = error.localizedDescription
            }
            pages[mode] = page
        }
    }

    /// The next page, when scrolling reaches the end.
    func loadMore(_ mode: FollowMode) async {
        let current = page(mode)
        guard current.loaded, current.hasMore, !loading.contains(mode), !loadingMore.contains(mode) else { return }
        loadingMore.insert(mode)
        defer { loadingMore.remove(mode) }
        do {
            let response = try await api.follows(mode, limit: Self.pageSize, offset: current.nextOffset)
            var page = pages[mode] ?? Page()
            page.profiles = dedupe(page.profiles + response.profiles)
            page.nextOffset = response.pagination?.nextOffset ?? current.nextOffset + response.profiles.count
            page.hasMore = (response.pagination?.hasMore ?? false) && !response.profiles.isEmpty
            pages[mode] = page
            remember(response.profiles, mode: mode)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dedupe(_ profiles: [FollowProfile]) -> [FollowProfile] {
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.profileId).inserted }
    }

    private func remember(_ profiles: [FollowProfile], mode: FollowMode) {
        for profile in profiles {
            if let isFollowing = profile.isFollowing {
                following[profile.profileId] = isFollowing
            } else if mode == .following {
                following[profile.profileId] = true
            }
        }
    }

    /// Makes sure we know whether you follow this person (a profile opened from a notification
    /// or a recipe), as the Expo app did by reading your Following list.
    func resolveFollowing(_ profileID: String) async {
        guard following[profileID] == nil, !followingResolved else { return }
        followingResolved = true
        do {
            let response = try await api.follows(.following, limit: 100, offset: 0)
            for profile in response.profiles { following[profile.profileId] = true }
            if following[profileID] == nil { following[profileID] = false }
        } catch {
            followingResolved = false
        }
    }

    // MARK: - Following

    /// Follows or unfollows right away, then confirms with the server (undone if it fails).
    /// Returns the new state, or nil when it didn't change.
    @discardableResult
    func toggleFollow(_ profileID: String) async -> Bool? {
        guard !followBusy.contains(profileID) else { return nil }
        let was = isFollowing(profileID)
        let next = !was
        followBusy.insert(profileID)
        following[profileID] = next
        adjustFollowerCount(profileID, by: next ? 1 : -1)
        defer { followBusy.remove(profileID) }
        do {
            try await api.setFollowing(profileID, following: next)
            if !next, var page = pages[.following] {
                page.profiles.removeAll { $0.profileId == profileID }
                pages[.following] = page
            }
            if next { stale.insert(.following) }
            return next
        } catch {
            following[profileID] = was
            adjustFollowerCount(profileID, by: next ? -1 : 1)
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func adjustFollowerCount(_ profileID: String, by delta: Int) {
        for mode in pages.keys {
            guard var page = pages[mode], let index = page.profiles.firstIndex(where: { $0.profileId == profileID }) else { continue }
            if let count = page.profiles[index].followerCount {
                page.profiles[index].followerCount = max(0, count + delta)
            }
            page.profiles[index].isFollowing = following[profileID]
            pages[mode] = page
        }
    }

    // MARK: - Blocking

    func loadBlocked() async {
        do {
            let ids = try await api.blockedProfiles()
            blocked = Set(ids)
            blockedLoaded = true
        } catch {
            // Lists still work without it.
        }
    }

    func block(_ profileID: String) async throws {
        try await api.block(profileID)
        blocked.insert(profileID)
        following[profileID] = false
        for mode in [FollowMode.following, .followers] {
            if var page = pages[mode] {
                page.profiles.removeAll { $0.profileId == profileID }
                pages[mode] = page
            }
        }
        await loadInvitations()
    }

    func unblock(_ profileID: String) async throws {
        try await api.unblock(profileID)
        blocked.remove(profileID)
    }

    // MARK: - Household invitations

    func loadInvitations() async {
        guard AppModel.shared.isOrganizer else {
            sentInvitations = []
            return
        }
        if let response = try? await api.householdInvitations() {
            sentInvitations = response.sent.filter { $0.status == .pending }
        }
    }

    func invite(_ profileID: String) async throws {
        let invitation = try await api.sendHouseholdInvitation(to: profileID)
        sentInvitations.removeAll { $0.id == invitation.id }
        sentInvitations.append(invitation)
        await loadInvitations()
    }

    func cancelInvitation(_ invitation: HouseholdInvitation) async throws {
        _ = try await api.cancelInvitation(invitation.id)
        sentInvitations.removeAll { $0.id == invitation.id }
        await loadInvitations()
    }
}

/// Opening someone's profile from a Community list.
struct CommunityProfileRoute: Hashable {
    var id: String
}

/// Words for people's profiles.
enum CommunityFormat {
    static func name(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "BigTable user" : trimmed
    }

    /// "Joined March 2025".
    static func joined(_ iso: String?) -> String? {
        guard let date = ISODay.timestamp(iso) else { return nil }
        return "Joined \(date.formatted(.dateTime.month(.wide).year()))"
    }

    /// "Joined BigTable March 2025", as the Expo profile said it.
    static func joinedBigTable(_ iso: String?) -> String? {
        guard let date = ISODay.timestamp(iso) else { return nil }
        return "Joined BigTable \(date.formatted(.dateTime.month(.wide).year()))"
    }

    static func since(_ iso: String?) -> String? {
        guard let date = ISODay.timestamp(iso) else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }
}
