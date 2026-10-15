import Foundation

/// The words and symbols for each kind of notification, ported from the Expo app's copy
/// ("Anna liked your recipe Sheet-Pan Fajitas.").
enum NotificationText {
    /// Names longer than this are shortened, as the API and the Expo app did.
    static let nameLimit = 30

    /// The sentence for a notification.
    static func summary(_ notification: NotificationRecord) -> String {
        let actor = actorFirstName(notification)
        let recipe = recipeTitle(notification)
        switch notification.kind {
        case .recipePublished:
            return recipe.map { "\(actor) published \($0)." } ?? "\(actor) published a new recipe."
        case .recipeUpdated:
            return recipe.map { "\(actor) updated \($0)." } ?? "\(actor) updated a recipe you follow."
        case .recipeLiked:
            return recipe.map { "\(actor) liked your recipe \($0)." } ?? "\(actor) liked your recipe."
        case .recipeSaved:
            return recipe.map { "\(actor) saved your recipe \($0)." } ?? "\(actor) saved your recipe."
        case .newFollower:
            return "\(actor) started following you."
        case .householdInvitation:
            return "\(actor) invited you to join their household."
        case .householdInvitationAccepted:
            return "\(actor) accepted your household invitation."
        case .householdInvitationDeclined:
            return "\(actor) declined your household invitation."
        case .householdMemberRemoved:
            let household = truncated(notification.data["organizerHouseholdName"]?.string, fallback: "")
            return household.isEmpty ? "You've been removed from a household." : "You've been removed from \(household)'s household."
        case .householdMemberLeft:
            return "\(actor) has left your household."
        case .householdMemberPermissionsChanged:
            return "Your organizer has updated your household permissions."
        case nil:
            return "New notification"
        }
    }

    /// The short heading above the sentence (the Expo app's NOTIFICATION_LABELS).
    static func label(_ notification: NotificationRecord) -> String {
        switch notification.kind {
        case .recipePublished: "New recipe from someone you follow"
        case .recipeUpdated: "Recipe update"
        case .recipeLiked: "Someone liked your recipe"
        case .recipeSaved: "Someone saved your recipe"
        case .newFollower: "New follower"
        case .householdInvitation: "Household invitation"
        case .householdInvitationAccepted: "Invitation accepted"
        case .householdInvitationDeclined: "Invitation declined"
        case .householdMemberRemoved: "Removed from household"
        case .householdMemberLeft: "Member left household"
        case .householdMemberPermissionsChanged: "Permissions changed"
        case nil: "Notification"
        }
    }

    /// The SF Symbol for the kind of notification (the Expo app's icons).
    static func symbol(_ notification: NotificationRecord) -> String {
        switch notification.kind {
        case .householdInvitation: "person.crop.circle.badge.plus"
        case .householdInvitationAccepted: "checkmark.circle.fill"
        case .householdInvitationDeclined: "xmark.circle.fill"
        case .householdMemberRemoved: "person.crop.circle.badge.xmark"
        case .householdMemberLeft: "person.fill.xmark"
        case .householdMemberPermissionsChanged: "lock.shield"
        case .newFollower: "person.2.fill"
        case .recipeLiked: "heart.fill"
        case .recipeSaved: "bookmark.fill"
        case .recipeUpdated: "arrow.triangle.2.circlepath"
        case .recipePublished, nil: "megaphone.fill"
        }
    }

    /// The actor's full name (shortened), from the record or its data.
    static func actorName(_ notification: NotificationRecord, fallback: String = "Someone") -> String {
        let fromRecord = notification.actorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fromData = notification.data["actorName"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return truncated(fromRecord.isEmpty ? fromData : fromRecord, fallback: fallback)
    }

    static func actorFirstName(_ notification: NotificationRecord) -> String {
        let full = actorName(notification, fallback: "")
        guard !full.isEmpty else { return "Someone" }
        return full.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? full
    }

    static func recipeTitle(_ notification: NotificationRecord) -> String? {
        guard let title = notification.data["recipeTitle"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    /// The household invitation a notification is about, for Accept and Decline.
    static func invitationID(_ notification: NotificationRecord) -> String? {
        guard let id = notification.data["invitationId"]?.string, !id.isEmpty else { return nil }
        return id
    }

    static func truncated(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return fallback }
        guard trimmed.count > nameLimit else { return trimmed }
        return String(trimmed.prefix(nameLimit - 3)) + "..."
    }

    /// "5m ago", "3h ago", "2d ago", then the date, as the Expo inbox showed it.
    static func time(_ iso: String) -> String {
        guard let date = ISODay.timestamp(iso) else { return "Just now" }
        let minutes = Int(Date.now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
