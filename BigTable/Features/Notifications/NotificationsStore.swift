import Foundation
import Observation
import OSLog

/// The inbox: notifications 20 at a time (all, or unread only), read and unread changes made
/// right away and confirmed with the server, and household invitations answered in place.
/// Keeps the bell's unread count (`AppModel.unreadCount`) in step.
@MainActor
@Observable
final class NotificationsStore {
    /// The Expo app's page size.
    static let pageSize = 20

    private(set) var items: [NotificationRecord] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var isMarkingAll = false
    /// Accept or Decline waiting on the server, by notification id.
    private(set) var responding: [String: Bool] = [:]
    var unreadOnly = false
    var errorMessage: String?

    private var nextOffset = 0
    private let api = BigTableAPI.shared
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "notifications")

    var hasUnread: Bool { items.contains { $0.isUnread } }

    // MARK: - Loading

    func load() async {
        if !hasLoaded { isLoading = true }
        defer { isLoading = false }
        do {
            let response = try await api.notifications(limit: Self.pageSize, offset: 0, unreadOnly: unreadOnly)
            items = response.notifications
            update(paging: response, offset: 0)
            hasLoaded = true
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("Couldn't load notifications: \(error.localizedDescription, privacy: .public)")
            if hasLoaded { errorMessage = error.localizedDescription } else { loadError = error.localizedDescription }
        }
        await AppModel.shared.refreshUnreadCount()
    }

    func loadMore() async {
        guard hasLoaded, hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let offset = nextOffset
            let response = try await api.notifications(limit: Self.pageSize, offset: offset, unreadOnly: unreadOnly)
            let known = Set(items.map(\.id))
            items.append(contentsOf: response.notifications.filter { !known.contains($0.id) })
            update(paging: response, offset: offset)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update(paging response: NotificationsResponse, offset: Int) {
        let count = response.notifications.count
        nextOffset = response.pagination?.nextOffset ?? offset + count
        if let hasMore = response.pagination?.hasMore {
            self.hasMore = hasMore
        } else if let total = response.pagination?.totalCount {
            hasMore = offset + count < total
        } else {
            hasMore = count >= Self.pageSize
        }
        if count == 0 { hasMore = false }
    }

    // MARK: - Read and unread

    func markRead(_ notification: NotificationRecord) async {
        guard let index = items.firstIndex(where: { $0.id == notification.id }), items[index].isUnread else { return }
        items[index].readAt = ISO8601DateFormatter().string(from: .now)
        adjustUnread(by: -1)
        do {
            try await api.markNotificationsRead(ids: [notification.id])
        } catch {
            if let index = items.firstIndex(where: { $0.id == notification.id }) { items[index].readAt = nil }
            adjustUnread(by: 1)
            errorMessage = error.localizedDescription
        }
    }

    func markUnread(_ notification: NotificationRecord) async {
        guard let index = items.firstIndex(where: { $0.id == notification.id }), !items[index].isUnread else { return }
        let previous = items[index].readAt
        items[index].readAt = nil
        adjustUnread(by: 1)
        do {
            try await api.markNotificationsUnread(ids: [notification.id])
        } catch {
            if let index = items.firstIndex(where: { $0.id == notification.id }) { items[index].readAt = previous }
            adjustUnread(by: -1)
            errorMessage = error.localizedDescription
        }
    }

    func markAllRead() async {
        guard hasUnread, !isMarkingAll else { return }
        let before = items
        let now = ISO8601DateFormatter().string(from: .now)
        isMarkingAll = true
        defer { isMarkingAll = false }
        for index in items.indices where items[index].readAt == nil { items[index].readAt = now }
        AppModel.shared.setUnreadCount(0)
        do {
            try await api.markNotificationsRead(all: true)
            if unreadOnly { await load() }
        } catch {
            items = before
            errorMessage = error.localizedDescription
            await AppModel.shared.refreshUnreadCount()
        }
    }

    private func adjustUnread(by delta: Int) {
        AppModel.shared.setUnreadCount(max(0, AppModel.shared.unreadCount + delta))
    }

    // MARK: - Household invitations

    /// Accepts or declines an invitation from its notification. Accepting reloads the
    /// household, since this person now sees the organizer's plan and list. Returns false if
    /// it didn't go through; `errorMessage` says why.
    func respond(to notification: NotificationRecord, accept: Bool) async -> Bool {
        guard let invitationID = NotificationText.invitationID(notification), responding[notification.id] == nil else { return false }
        responding[notification.id] = accept
        defer { responding[notification.id] = nil }
        do {
            _ = try await api.respondToInvitation(invitationID, accept: accept)
            try? await api.markNotificationsRead(ids: [notification.id])
            if let index = items.firstIndex(where: { $0.id == notification.id }), items[index].isUnread {
                items[index].readAt = ISO8601DateFormatter().string(from: .now)
            }
            if accept { await AppModel.shared.reload() }
            await load()
            return true
        } catch let error as APIError where error.status == 404 {
            errorMessage = "This invitation is no longer available."
            await load()
        } catch let error as APIError where error.status == 409 {
            errorMessage = error.message ?? "You can't join this household right now."
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }
}
