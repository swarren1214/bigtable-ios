import Foundation

/// One person while the household is being set up or edited: their name, age, likes and
/// dislikes, photo and dietary restrictions, before it's saved to the API.
nonisolated struct ProfileMemberDraft: Identifiable, Hashable, Sendable {
    /// Local identity for lists and sheets (the API's id can be missing for new people).
    var id: String = UUID().uuidString
    /// The API's household member id, kept so saving updates the row instead of replacing it.
    var serverID: String?
    /// Set when this person joined from their own BigTable account.
    var linkedProfileId: String?
    /// Where the person sat in the API's list (its creation order), used to work out the
    /// restriction keys the same way the Expo app did.
    var originalIndex: Int?
    var name: String = ""
    var dateOfBirth: Date?
    var likes: [String] = []
    var dislikes: [String] = []
    /// The photo as the API stores it: a `member-avatars` object path, or a full URL.
    var avatar: String?
    /// "Vegetarian", "Nut-Free"…
    var restrictions: [String] = []

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var displayName: String { trimmedName.isEmpty ? "New person" : trimmedName }
    var isJoined: Bool { !(linkedProfileId ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var avatarURL: String? { ProfileAvatar.url(for: avatar) }

    var age: Int? {
        guard let dateOfBirth else { return nil }
        return Calendar.current.dateComponents([.year], from: dateOfBirth, to: .now).year
    }

    /// "Adult", "Child", or "Family member" when there's no date of birth.
    var ageLabel: String {
        guard let age else { return "Family member" }
        return age >= 18 ? "Adult" : "Child"
    }

    var restrictionSummary: String {
        switch restrictions.count {
        case 0: "No dietary restrictions"
        case 1: "1 restriction"
        default: "\(restrictions.count) restrictions"
        }
    }

    init() {}

    init(member: HouseholdMember, originalIndex: Int?) {
        serverID = member.id
        linkedProfileId = member.linkedProfileId
        self.originalIndex = originalIndex
        name = member.name
        dateOfBirth = member.dateOfBirth.flatMap { ISODay.date(from: $0) }
        likes = member.likes
        dislikes = member.dislikes
        avatar = member.avatarUrl
    }
}

/// Member photos: the API stores either an object path in the `member-avatars` bucket
/// ("<user>/<key>-<time>.jpg", what the Expo app saved) or a full public URL.
nonisolated enum ProfileAvatar {
    static let publicPrefix = "/storage/v1/object/public/member-avatars/"

    /// A URL `MemberAvatar` can load.
    static func url(for stored: String?) -> String? {
        guard let value = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("http") { return value }
        return StorageClient.shared.publicURL(bucket: .memberAvatars, path: value)
    }

    /// What to save for an uploaded photo's public URL: its object path, as the Expo app did,
    /// so both apps read it.
    static func storedValue(forUploadedURL url: String) -> String {
        guard let range = url.range(of: publicPrefix) else { return url }
        let rest = String(url[range.upperBound...])
        let path = rest.split(separator: "?").first.map(String.init) ?? rest
        let decoded = path.removingPercentEncoding ?? path
        return decoded.isEmpty ? url : decoded
    }
}

/// The household while it's being edited: its name and people. Converts to and from the API,
/// keeping dietary restrictions keyed the way the Expo app keyed them ("adult1", "adult2",
/// "adult_extra_0", "child_0"), so households set up in either app read the same.
nonisolated struct HouseholdDraft: Hashable, Sendable {
    var name: String = ""
    var members: [ProfileMemberDraft] = []

    /// The dietary restrictions the Expo app offered, in its order.
    static let dietaryOptions = [
        "Vegetarian", "Vegan", "Gluten-Free", "Dairy-Free",
        "Milk-Free", "Nut-Free", "Egg-Free", "Soy-Free", "Halal",
        "Kosher", "Pescatarian", "Keto", "Paleo",
    ]
    static let maxMembers = 20
    static let maxNameLength = 120

    init() {}

    /// A new household with its first person (the organizer) filled in.
    init(firstName: String) {
        var first = ProfileMemberDraft()
        first.name = firstName
        members = [first]
    }

    /// The household from `/v1/bigtable/me`, as the Expo app read it.
    init(me: MeResponse, householdName: String, organizerProfileID: String?) {
        name = householdName
        let all = me.householdMembers
        let filtered = Self.withoutLegacyDuplicates(all)
        let drafts = filtered.map { member in
            ProfileMemberDraft(member: member, originalIndex: all.firstIndex(of: member))
        }
        var restrictionsByKey: [String: [String]] = [:]
        for restriction in me.dietaryRestrictions {
            let value = restriction.value.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if restrictionsByKey[restriction.type]?.contains(value) != true {
                restrictionsByKey[restriction.type, default: []].append(value)
            }
        }
        members = Self.keyed(drafts, organizerProfileID: organizerProfileID).map { entry in
            var member = entry.member
            member.restrictions = restrictionsByKey[entry.key] ?? []
            return member
        }
    }

    // MARK: Who can edit what

    /// The organizer edits everyone who hasn't joined with their own account; someone who
    /// joined edits only their own row (the API allows no more).
    static func canEdit(_ member: ProfileMemberDraft, isOrganizer: Bool, userID: String?) -> Bool {
        if member.isJoined {
            guard let userID else { return false }
            return member.linkedProfileId?.trimmingCharacters(in: .whitespaces) == userID
        }
        return isOrganizer
    }

    // MARK: People from Caloma

    /// The people in Caloma's family who aren't here yet, parents first (BigTable counts the
    /// first two people as the adults until there are birthdays), up to the household's limit.
    func newPeople(from family: HearthFamily) -> [String] {
        var names: [String] = []
        let ordered = family.members.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.role == "kid" ? 1 : 0
                let right = rhs.element.role == "kid" ? 1 : 0
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map { $0.element }
        for member in ordered {
            let name = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let known = members.contains { Self.sameName($0.name, name) } || names.contains { Self.sameName($0, name) }
            if !known { names.append(name) }
        }
        let room = max(0, Self.maxMembers - members.count)
        return Array(names.prefix(room))
    }

    /// Adds people by name only; their ages, likes and restrictions are filled in here later.
    mutating func addPeople(named names: [String]) {
        for name in names where members.count < Self.maxMembers {
            var member = ProfileMemberDraft()
            member.name = String(name.prefix(Self.maxNameLength))
            members.append(member)
        }
    }

    /// The same person, ignoring case and spacing. A first name alone matches a full name
    /// ("Steve" and "Steve Warren").
    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        func words(_ name: String) -> [String] {
            name.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        }
        let left = words(lhs)
        let right = words(rhs)
        guard let leftFirst = left.first, let rightFirst = right.first else { return false }
        if left == right { return true }
        return (left.count == 1 || right.count == 1) && leftFirst == rightFirst
    }

    // MARK: Saving

    nonisolated enum ValidationError: LocalizedError {
        case missingHouseholdName
        case householdNameTooLong
        case missingFirstName
        case tooManyMembers
        case nothingToSave

        var errorDescription: String? {
            switch self {
            case .missingHouseholdName: "Give your household a name."
            case .householdNameTooLong: "Household names can be up to 120 characters."
            case .missingFirstName: "Add your name as the first person."
            case .tooManyMembers: "A household can have up to 20 people."
            case .nothingToSave: "There's nothing here you can change."
            }
        }
    }

    /// `PUT /v1/bigtable/me` for this household. The organizer sends everyone they manage; someone
    /// who joined sends only their own row and its restrictions.
    func payload(isOrganizer: Bool, userID: String?, organizerProfileID: String?, householdName fixedName: String? = nil) throws -> SaveHouseholdPayload {
        let householdName = (fixedName ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
        if isOrganizer {
            if householdName.isEmpty { throw ValidationError.missingHouseholdName }
            if householdName.count > Self.maxNameLength { throw ValidationError.householdNameTooLong }
            if members.first?.trimmedName.isEmpty != false { throw ValidationError.missingFirstName }
        }
        let named = members.filter { !$0.trimmedName.isEmpty }
        if named.count > Self.maxMembers { throw ValidationError.tooManyMembers }

        // The API returns people in the order they were created: everyone it already has, in
        // its order, then the new people in the order they were added.
        let creationOrder = named.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.originalIndex ?? (100_000 + lhs.offset)
                let right = rhs.element.originalIndex ?? (100_000 + rhs.offset)
                return left < right
            }
            .map { $0.element }
        let keyed = Self.keyed(creationOrder, organizerProfileID: organizerProfileID)

        var householdMembers: [HouseholdMember] = []
        var restrictions: [DietaryRestriction] = []
        for entry in keyed {
            let member = entry.member
            let editable = Self.canEdit(member, isOrganizer: isOrganizer, userID: userID)
            if editable && (isOrganizer ? !member.isJoined : true) {
                householdMembers.append(HouseholdMember(
                    id: member.serverID,
                    linkedProfileId: nil,
                    name: member.trimmedName,
                    dateOfBirth: member.dateOfBirth.map { ISODay.string(from: $0) },
                    likes: Self.cleaned(member.likes),
                    dislikes: Self.cleaned(member.dislikes),
                    avatarUrl: member.avatar
                ))
            }
            // The organizer's save replaces every restriction in the household, so it keeps
            // the joined people's too; a joined person's save only touches their own.
            if isOrganizer || editable {
                for value in member.restrictions {
                    restrictions.append(DietaryRestriction(id: nil, type: entry.key, value: value))
                }
            }
        }
        if !isOrganizer && householdMembers.isEmpty { throw ValidationError.nothingToSave }
        return SaveHouseholdPayload(
            householdName: householdName,
            avatarUrl: nil,
            householdMembers: householdMembers,
            dietaryRestrictions: Array(restrictions.prefix(50))
        )
    }

    // MARK: The Expo app's member keys

    /// Adults first (no date of birth counts as an adult) with the organizer's own row at the
    /// front, then children; keys by position. With no dates of birth at all, the first two
    /// people are the adults.
    static func keyed(_ members: [ProfileMemberDraft], organizerProfileID: String?) -> [(key: String, member: ProfileMemberDraft)] {
        let hasDatesOfBirth = members.contains { $0.dateOfBirth != nil }
        var adults: [ProfileMemberDraft]
        let children: [ProfileMemberDraft]
        if hasDatesOfBirth {
            adults = members.filter { ($0.age ?? 18) >= 18 }
            children = members.filter { ($0.age ?? 18) < 18 }
        } else {
            adults = Array(members.prefix(2))
            children = Array(members.dropFirst(2))
        }
        let organizerIndex = adults.firstIndex { member in
            let linked = (member.linkedProfileId ?? "").trimmingCharacters(in: .whitespaces)
            return linked.isEmpty || linked == organizerProfileID
        }
        if let organizerIndex, organizerIndex > 0 {
            let organizer = adults.remove(at: organizerIndex)
            adults.insert(organizer, at: 0)
        }
        var result: [(key: String, member: ProfileMemberDraft)] = []
        for (index, member) in adults.enumerated() {
            let key = index == 0 ? "adult1" : index == 1 ? "adult2" : "adult_extra_\(index - 2)"
            result.append((key: key, member: member))
        }
        for (index, member) in children.enumerated() {
            result.append((key: "child_\(index)", member: member))
        }
        return result
    }

    /// Drops the placeholder rows older Expo builds left behind when someone joined: an
    /// unlinked row with the same name as a joined person that matches their photo or date of
    /// birth, or has nothing else in it.
    static func withoutLegacyDuplicates(_ members: [HouseholdMember]) -> [HouseholdMember] {
        func nameKey(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func isLinked(_ member: HouseholdMember) -> Bool {
            !(member.linkedProfileId ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        var linkedByName: [String: [(avatar: String, dob: String)]] = [:]
        for member in members where isLinked(member) {
            let key = nameKey(member.name)
            guard !key.isEmpty else { continue }
            linkedByName[key, default: []].append((
                (member.avatarUrl ?? "").trimmingCharacters(in: .whitespaces),
                (member.dateOfBirth ?? "").trimmingCharacters(in: .whitespaces)
            ))
        }
        return members.filter { member in
            if isLinked(member) { return true }
            let key = nameKey(member.name)
            guard !key.isEmpty, let candidates = linkedByName[key], !candidates.isEmpty else { return true }
            let avatar = (member.avatarUrl ?? "").trimmingCharacters(in: .whitespaces)
            let dob = (member.dateOfBirth ?? "").trimmingCharacters(in: .whitespaces)
            let matches = candidates.contains { candidate in
                (!avatar.isEmpty && avatar == candidate.avatar) || (!dob.isEmpty && dob == candidate.dob)
            }
            if matches { return false }
            if avatar.isEmpty && dob.isEmpty && member.likes.isEmpty && member.dislikes.isEmpty { return false }
            return true
        }
    }

    /// Likes and dislikes as the API takes them: trimmed, at most 50 characters, at most 20.
    static func cleaned(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(50)) }
            .prefix(20)
            .map { $0 }
    }
}
