import SwiftUI
import UIKit

/// The notifications inbox (opened from the bell): likes, saves, new followers, new and
/// updated recipes from people you follow, and household invitations, newest first. Tapping
/// one marks it read and opens the recipe or the person; invitations can be accepted or
/// declined right here. Swipe to mark read or unread.
///
/// The caller provides the NavigationStack.
struct NotificationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store = NotificationsStore()
    @State private var destination: NotificationsDestination?
    @State private var choice: NotificationsInvitationChoice?
    @State private var joinedHousehold: String?

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $store.unreadOnly) {
                    Text("All").tag(false)
                    Text("Unread").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }

            content
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                SheetCancelButton("Close") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.markAllRead() }
                } label: {
                    if store.isMarkingAll {
                        ProgressView()
                    } else {
                        Label("Mark All Read", systemImage: "envelope.open")
                    }
                }
                .disabled(!store.hasUnread || store.isMarkingAll)
                .accessibilityLabel("Mark all as read")
            }
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .onChange(of: store.unreadOnly) { _, _ in
            Task { await store.load() }
        }
        .navigationDestination(item: $destination) { destination in
            switch destination {
            case .recipe(let id, let versionID):
                RecipeDetailView(recipeID: id, versionID: versionID, showsCloseButton: false)
            case .profile(let id):
                PublicProfileView(profileID: id)
            }
        }
        .alert(
            choice?.title ?? "",
            isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }),
            presenting: choice
        ) { choice in
            Button("Cancel", role: .cancel) {}
            Button(choice.accept ? "Accept" : "Decline", role: choice.accept ? nil : ButtonRole.destructive) {
                Task { await respond(choice) }
            }
        } message: { choice in
            Text(choice.message)
        }
        .alert(
            "You've joined \(joinedHousehold ?? "the")'s household",
            isPresented: Binding(get: { joinedHousehold != nil }, set: { if !$0 { joinedHousehold = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can see their meal plan, grocery list and recipes, and the organizer decides what else you can do. Your own household is hidden while you're a member and comes back if you leave.")
        }
        .errorAlert($store.errorMessage)
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded, let error = store.loadError {
            Section {
                RetryCard(message: error) { Task { await store.load() } }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        } else if !store.hasLoaded {
            Section {
                LoadingCard(title: "Loading notifications…")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        } else if store.items.isEmpty {
            Section {
                ContentUnavailableView(
                    store.unreadOnly ? "No unread notifications" : "No notifications yet",
                    systemImage: store.unreadOnly ? "checkmark.circle" : "bell.slash",
                    description: Text(store.unreadOnly ? "You're all caught up." : "Activity from follows, likes and saves appears here.")
                )
                .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(store.items) { notification in
                    NotificationsRow(
                        notification: notification,
                        respondingAccept: store.responding[notification.id],
                        onOpen: { openNotification(notification) },
                        onRespond: { accept in
                            choice = NotificationsInvitationChoice(notification: notification, accept: accept)
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if notification.isUnread {
                            Button("Read", systemImage: "envelope.open") {
                                Task { await store.markRead(notification) }
                            }
                            .tint(.blue)
                        } else {
                            Button("Unread", systemImage: "envelope.badge") {
                                Task { await store.markUnread(notification) }
                            }
                            .tint(.blue)
                        }
                    }
                    .onAppear {
                        if notification.id == store.items.last?.id {
                            Task { await store.loadMore() }
                        }
                    }
                }
            }

            if store.isLoadingMore {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    /// Marks it read and goes where it points: the recipe, or the person (followers and
    /// other people's activity). Household notifications stay in the inbox, as in Expo.
    private func openNotification(_ notification: NotificationRecord) {
        Task { await store.markRead(notification) }
        if let recipeID = notification.recipeId {
            destination = .recipe(id: recipeID, versionID: notification.versionId)
            return
        }
        switch notification.kind {
        case .householdInvitation, .householdInvitationAccepted, .householdInvitationDeclined, .householdMemberRemoved, .householdMemberLeft, .householdMemberPermissionsChanged:
            return
        default:
            if let actor = notification.actorProfileId {
                destination = .profile(actor)
            }
        }
    }

    private func respond(_ choice: NotificationsInvitationChoice) async {
        let joined = await store.respond(to: choice.notification, accept: choice.accept)
        if joined, choice.accept {
            joinedHousehold = NotificationText.actorName(choice.notification, fallback: "the organizer")
        }
    }
}

/// Where a tapped notification leads.
enum NotificationsDestination: Hashable {
    case recipe(id: String, versionID: String?)
    case profile(String)
}

/// Accepting or declining an invitation, waiting for confirmation.
struct NotificationsInvitationChoice: Identifiable {
    var notification: NotificationRecord
    var accept: Bool

    var id: String { "\(notification.id)-\(accept)" }
    private var organizer: String { NotificationText.actorName(notification, fallback: "this organizer") }

    var title: String { accept ? "Accept invitation?" : "Decline invitation?" }
    var message: String {
        accept
            ? "Join \(organizer)'s household? Your own household data will be hidden while you're a member."
            : "Decline \(organizer)'s invitation?"
    }
}

/// One notification: who did it (their photo, with a badge for the kind), what happened,
/// when, and a dot while it's unread. A pending household invitation shows Accept and
/// Decline.
struct NotificationsRow: View {
    var notification: NotificationRecord
    /// true while accepting, false while declining, nil otherwise.
    var respondingAccept: Bool?
    var onOpen: () -> Void
    var onRespond: (Bool) -> Void

    @Environment(\.accent) private var accent

    init(notification: NotificationRecord, respondingAccept: Bool?, onOpen: @escaping () -> Void, onRespond: @escaping (Bool) -> Void) {
        self.notification = notification
        self.respondingAccept = respondingAccept
        self.onOpen = onOpen
        self.onRespond = onRespond
    }

    private var isUnread: Bool { notification.isUnread }
    private var showsInvitationActions: Bool {
        notification.kind == .householdInvitation && isUnread && NotificationText.invitationID(notification) != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                Text(NotificationText.label(notification))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(NotificationText.summary(notification))
                    .font(.subheadline.weight(isUnread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(NotificationText.time(notification.createdAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if showsInvitationActions {
                    HStack(spacing: 10) {
                        Button {
                            onRespond(true)
                        } label: {
                            HStack(spacing: 6) {
                                if respondingAccept == true { ProgressView() } else { Image(systemName: "checkmark") }
                                Text("Accept")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.glassProminent)

                        Button {
                            onRespond(false)
                        } label: {
                            HStack(spacing: 6) {
                                if respondingAccept == false { ProgressView() } else { Image(systemName: "xmark") }
                                Text("Decline")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.glass)
                    }
                    .disabled(respondingAccept != nil)
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 4)
            if isUnread {
                Circle()
                    .fill(accent)
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(isUnread ? "Unread. " : "")\(NotificationText.summary(notification)) \(NotificationText.time(notification.createdAt))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open") { onOpen() }
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            if notification.actorProfileId != nil || notification.actorAvatarUrl != nil {
                let name = NotificationText.actorName(notification, fallback: "?")
                MemberAvatar(name: name, color: PersonColor.forKey(notification.actorProfileId ?? name).color, url: notification.actorAvatarUrl, size: 44)
            } else {
                IconTile(symbol: NotificationText.symbol(notification), color: accent, size: 44)
            }
            Image(systemName: NotificationText.symbol(notification))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(isUnread ? accent : Color(.systemGray), in: Circle())
                .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                .offset(x: 4, y: 4)
        }
        .frame(width: 48, height: 48, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}
