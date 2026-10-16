import Foundation

// The BigTable API's shapes, one for one with the Expo app's `types/*.ts`. Field names match
// the JSON exactly (camelCase, except `MeResponse.profile`, which is snake_case). Optional
// fields are optional here too, so older and newer servers both decode.

// MARK: - Any JSON

/// A JSON value of any shape, for the few places the API sends free-form objects
/// (notification `data`, user metadata).
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var double: Double? { if case .number(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    subscript(key: String) -> JSONValue? { if case .object(let value) = self { value[key] } else { nil } }
}

/// `{ "ok": true }`, and the other small acknowledgements.
nonisolated struct OKResponse: Decodable, Sendable {
    var ok: Bool?
}

// MARK: - Planner

nonisolated enum DayOfWeek: String, Codable, CaseIterable, Identifiable, Sendable {
    // Sunday first: the API's weeks start on Sunday (`weekStart` is a Sunday).
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var short: String { String(rawValue.prefix(3)).capitalized }
    /// 0 for Sunday … 6 for Saturday.
    var offset: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

nonisolated enum MealSlotType: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .breakfast: "sun.horizon"
        case .lunch: "takeoutbag.and.cup.and.straw"
        case .dinner: "fork.knife"
        }
    }
}

nonisolated enum PlannerMealRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case entree, side, dessert, other

    var id: String { rawValue }
    var label: String { rawValue == "entree" ? "Entree" : rawValue.capitalized }
}

nonisolated enum RecipeStatus: String, Codable, Sendable {
    case draft, published, unpublished, removed
}

nonisolated struct PlannerMealItem: Codable, Hashable, Sendable {
    var title: String
    var role: PlannerMealRole
    var imageUrl: String?
    var recipeId: String?
    var recipeVersionId: String?
    /// "library", "custom" or "dine_out".
    var source: String?
    var recipeStatus: RecipeStatus?
    var currentVersionId: String?
    var hasUpdateAvailable: Bool?
}

nonisolated struct PlannerDineOut: Codable, Hashable, Sendable {
    var label: String
    var name: String?
    var address: String?
    var phone: String?
    var latitude: Double?
    var longitude: Double?
    var logoUrl: String?
    var website: String?
    var hours: String?
    var price: String?
    var cuisine: String?
}

nonisolated struct PlannerSnackItem: Codable, Hashable, Sendable, Identifiable {
    var offId: String
    var description: String
    var brandOwner: String?
    var imageUrl: String?
    var servingSize: String?
    var calories: Double?

    var id: String { offId }
}

nonisolated struct PlannerSlot: Codable, Hashable, Sendable {
    var id: String?
    var customMeal: String?
    var dineOut: PlannerDineOut?
    var recipeItems: [PlannerMealItem]
    var snackItems: [PlannerSnackItem]
    var excludedMembers: [String]
    var completed: Bool

    init(id: String? = nil, customMeal: String? = nil, dineOut: PlannerDineOut? = nil, recipeItems: [PlannerMealItem] = [], snackItems: [PlannerSnackItem] = [], excludedMembers: [String] = [], completed: Bool = false) {
        self.id = id
        self.customMeal = customMeal
        self.dineOut = dineOut
        self.recipeItems = recipeItems
        self.snackItems = snackItems
        self.excludedMembers = excludedMembers
        self.completed = completed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        customMeal = try c.decodeIfPresent(String.self, forKey: .customMeal)
        dineOut = try c.decodeIfPresent(PlannerDineOut.self, forKey: .dineOut)
        recipeItems = try c.decodeIfPresent([PlannerMealItem].self, forKey: .recipeItems) ?? []
        snackItems = try c.decodeIfPresent([PlannerSnackItem].self, forKey: .snackItems) ?? []
        excludedMembers = try c.decodeIfPresent([String].self, forKey: .excludedMembers) ?? []
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
    }

    /// Nothing planned: no recipes, no custom meal, not eating out.
    var isEmpty: Bool {
        recipeItems.isEmpty && (customMeal ?? "").trimmingCharacters(in: .whitespaces).isEmpty && dineOut == nil
    }

    /// "Sheet-Pan Fajitas + Rice", "Leftovers", "Dinner at Café Rio".
    var title: String {
        if let dineOut { return dineOut.name ?? dineOut.label }
        if !recipeItems.isEmpty { return recipeItems.map(\.title).joined(separator: " + ") }
        return customMeal ?? ""
    }
}

nonisolated struct PlannerResponse: Codable, Sendable {
    var planId: String
    var weekStart: String
    var days: [String: [String: PlannerSlot]]

    func slot(_ day: DayOfWeek, _ slot: MealSlotType) -> PlannerSlot {
        days[day.rawValue]?[slot.rawValue] ?? PlannerSlot()
    }

    mutating func set(_ value: PlannerSlot, day: DayOfWeek, slot: MealSlotType) {
        var dayValue = days[day.rawValue] ?? [:]
        dayValue[slot.rawValue] = value
        days[day.rawValue] = dayValue
    }
}

nonisolated struct PlannerSlotUpdateResponse: Decodable, Sendable {
    var day: DayOfWeek
    var slot: MealSlotType
    var weekStart: String
    var planId: String
    var slotData: PlannerSlot
}

/// `PUT /v1/bigtable/plans/current`. Only the fields that are set are changed.
nonisolated struct PlanSlotUpdate: Encodable, Sendable {
    var weekStart: String?
    var day: DayOfWeek
    var slot: MealSlotType
    var customMeal: String??
    var dineOut: PlannerDineOut??
    var recipeItems: [PlannerMealItem]?
    var snackItems: [PlannerSnackItem]?
    var excludedMembers: [String]?
    var completed: Bool?

    init(weekStart: String?, day: DayOfWeek, slot: MealSlotType) {
        self.weekStart = weekStart
        self.day = day
        self.slot = slot
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(weekStart, forKey: .weekStart)
        try c.encode(day, forKey: .day)
        try c.encode(slot, forKey: .slot)
        // A double optional: absent = leave as is, .some(nil) = clear it.
        if let customMeal { try c.encode(customMeal, forKey: .customMeal) }
        if let dineOut { try c.encode(dineOut, forKey: .dineOut) }
        try c.encodeIfPresent(recipeItems, forKey: .recipeItems)
        try c.encodeIfPresent(snackItems, forKey: .snackItems)
        try c.encodeIfPresent(excludedMembers, forKey: .excludedMembers)
        try c.encodeIfPresent(completed, forKey: .completed)
    }

    enum CodingKeys: String, CodingKey {
        case weekStart, day, slot, customMeal, dineOut, recipeItems, snackItems, excludedMembers, completed
    }
}

// MARK: - Recipes

/// One ingredient as the API stores it: an amount, a measurement ("cup", "lb", "each"…) and a
/// name. `measurementType` values are the Expo app's MEASUREMENT_OPTIONS.
nonisolated struct RecipeIngredientInput: Codable, Hashable, Sendable {
    var amount: Double?
    var measurementType: String?
    var name: String
}

nonisolated struct RecipeIngredient: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var amount: Double?
    var measurementType: String?
    var name: String

    var input: RecipeIngredientInput { RecipeIngredientInput(amount: amount, measurementType: measurementType, name: name) }
}

nonisolated struct RecipeSummary: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var description: String?
    var imageUrl: String?
    var prepMinutes: Int?
    var cookMinutes: Int?
    var baseServings: Double
    var difficulty: String?
    var tags: [String]
    var sourceName: String
    var sourceUrl: String?
    var attributionRequired: Bool
    var attributionText: String?
    var isFavorite: Bool
    var isLiked: Bool?
    var likeCount: Int?
    var createdByProfileId: String?
    var creatorName: String?
    var creatorAvatarUrl: String?
    var status: RecipeStatus?
    var currentVersionId: String?
    var pinnedVersionId: String?
    var hasUpdateAvailable: Bool?
    var publishedAt: String?

    var totalMinutes: Int { (prepMinutes ?? 0) + (cookMinutes ?? 0) }
    /// The household wrote it (as opposed to the catalog or another family).
    var isUserRecipe: Bool { sourceName == "user" }
}

nonisolated struct RecipeDetail: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var description: String?
    var imageUrl: String?
    var prepMinutes: Int?
    var cookMinutes: Int?
    var baseServings: Double
    var difficulty: String?
    var tags: [String]
    var sourceName: String
    var sourceUrl: String?
    var attributionRequired: Bool
    var attributionText: String?
    var isFavorite: Bool
    var isLiked: Bool?
    var likeCount: Int?
    var createdByProfileId: String?
    var creatorName: String?
    var creatorAvatarUrl: String?
    var status: RecipeStatus?
    var currentVersionId: String?
    var pinnedVersionId: String?
    var hasUpdateAvailable: Bool?
    var publishedAt: String?
    var instructions: [String]
    var ingredients: [RecipeIngredient]
    var versionCount: Int?

    var isUserRecipe: Bool { sourceName == "user" }
    var totalMinutes: Int { (prepMinutes ?? 0) + (cookMinutes ?? 0) }
}

nonisolated struct Pagination: Codable, Hashable, Sendable {
    var limit: Int?
    var offset: Int?
    var hasMore: Bool?
    var nextOffset: Int?
    var totalCount: Int?
}

nonisolated struct RecipeListResponse: Decodable, Sendable {
    var recipes: [RecipeSummary]
    var pagination: Pagination?
}

nonisolated struct RecipeDetailResponse: Decodable, Sendable {
    var recipe: RecipeDetail
}

nonisolated struct CreateRecipeResponse: Decodable, Sendable {
    var id: String
}

/// `POST /v1/bigtable/recipes` and `PATCH /v1/bigtable/recipes/{id}`.
nonisolated struct RecipePayload: Encodable, Sendable {
    var title: String
    var imageUrl: String
    var description: String?
    var prepMinutes: Int?
    var cookMinutes: Int?
    var baseServings: Double?
    var difficulty: String?
    var tags: [String]?
    var ingredients: [RecipeIngredientInput]?
    var instructions: [String]?
}

nonisolated struct CustomTag: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var normalized: String
}

nonisolated struct CustomTagsResponse: Decodable, Sendable { var tags: [CustomTag] }
nonisolated struct CustomTagResponse: Decodable, Sendable { var tag: CustomTag }

nonisolated struct GenerateRecipeImageResponse: Decodable, Sendable {
    var dataBase64: String
    var mimeType: String
    var model: String?
}

nonisolated struct ScanRecipeDocumentResponse: Decodable, Sendable {
    var title: String?
    var ingredients: [String]
    var instructions: [String]
}

/// From a recording, a transcript or a web page.
nonisolated struct GeneratedRecipeResponse: Decodable, Sendable {
    var isRecipe: Bool
    var title: String?
    var description: String?
    var baseServings: Double?
    var tags: [String]
    var ingredients: [String]
    var instructions: [String]
    var failureReason: String?
    /// Filled in on the device (a recipe site's data or the on-device model); the API
    /// doesn't send these.
    var prepMinutes: Int?
    var cookMinutes: Int?
    /// "easy", "medium" or "hard".
    var difficulty: String?
    /// From recipe-refine: what AI changed, in a sentence or two.
    var reply: String?
}

nonisolated struct PublishRecipeResponse: Decodable, Sendable {
    var ok: Bool?
    var recipeId: String
    var versionId: String?
    var versionNumber: Int?
    var status: RecipeStatus
}

nonisolated struct RecipeLikeStateResponse: Decodable, Sendable { var liked: Bool }

// MARK: - Profile and household

nonisolated struct HouseholdMember: Codable, Hashable, Sendable {
    var id: String?
    var linkedProfileId: String?
    var name: String
    /// YYYY-MM-DD.
    var dateOfBirth: String?
    var likes: [String]
    var dislikes: [String]
    var avatarUrl: String?

    init(id: String? = nil, linkedProfileId: String? = nil, name: String, dateOfBirth: String? = nil, likes: [String] = [], dislikes: [String] = [], avatarUrl: String? = nil) {
        self.id = id
        self.linkedProfileId = linkedProfileId
        self.name = name
        self.dateOfBirth = dateOfBirth
        self.likes = likes
        self.dislikes = dislikes
        self.avatarUrl = avatarUrl
    }

    enum CodingKeys: String, CodingKey {
        case id, linkedProfileId, linked_profile_id, name, dateOfBirth, date_of_birth, likes, dislikes, avatarUrl, avatar_url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        linkedProfileId = try c.decodeIfPresent(String.self, forKey: .linkedProfileId) ?? c.decodeIfPresent(String.self, forKey: .linked_profile_id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        dateOfBirth = try c.decodeIfPresent(String.self, forKey: .dateOfBirth) ?? c.decodeIfPresent(String.self, forKey: .date_of_birth)
        likes = try c.decodeIfPresent([String].self, forKey: .likes) ?? []
        dislikes = try c.decodeIfPresent([String].self, forKey: .dislikes) ?? []
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl) ?? c.decodeIfPresent(String.self, forKey: .avatar_url)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(linkedProfileId, forKey: .linkedProfileId)
        try c.encode(name, forKey: .name)
        try c.encode(dateOfBirth, forKey: .dateOfBirth)
        try c.encode(likes, forKey: .likes)
        try c.encode(dislikes, forKey: .dislikes)
        try c.encode(avatarUrl, forKey: .avatarUrl)
    }

    /// Age in whole years from `dateOfBirth`, or nil.
    func age(on date: Date = .now) -> Int? {
        guard let dateOfBirth, let birth = ISODay.date(from: dateOfBirth) else { return nil }
        return Calendar.current.dateComponents([.year], from: birth, to: date).year
    }
}

nonisolated struct DietaryRestriction: Codable, Hashable, Sendable {
    var id: String?
    /// "allergy", "diet", "dislike"… as the Expo app saved them.
    var type: String
    var value: String
}

nonisolated enum HouseholdRole: String, Codable, Sendable {
    case organizer, member
}

nonisolated struct HouseholdMemberPermissions: Codable, Hashable, Sendable {
    var canManageMealPlan: Bool
    var canUseAiMealPlan: Bool
    var canUseAiGrocery: Bool
    var canEditMembers: Bool

    static let organizer = HouseholdMemberPermissions(canManageMealPlan: true, canUseAiMealPlan: true, canUseAiGrocery: true, canEditMembers: true)
    static let none = HouseholdMemberPermissions(canManageMealPlan: false, canUseAiMealPlan: false, canUseAiGrocery: false, canEditMembers: false)
}

nonisolated struct HouseholdIdentityMember: Codable, Hashable, Sendable {
    var name: String
    var avatarUrl: String?
}

nonisolated struct MembershipInfo: Codable, Hashable, Sendable {
    var role: HouseholdRole
    var organizerProfileId: String
    var organizerHouseholdName: String?
    var pendingInvitationCount: Int
}

nonisolated struct MeProfile: Codable, Hashable, Sendable {
    var id: String
    var householdName: String?
    var avatarUrl: String?
    var createdAt: String?
    var socialProfileVisible: Bool?
    var tutorialComplete: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case householdName = "household_name"
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
        case socialProfileVisible = "social_profile_visible"
        case tutorialComplete = "tutorial_complete"
    }
}

nonisolated struct MeResponse: Decodable, Sendable {
    var profile: MeProfile?
    var householdMembers: [HouseholdMember]
    var dietaryRestrictions: [DietaryRestriction]
    var myMember: HouseholdIdentityMember?
    var membership: MembershipInfo?

    enum CodingKeys: String, CodingKey { case profile, householdMembers, dietaryRestrictions, myMember, membership }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(MeProfile.self, forKey: .profile)
        householdMembers = try c.decodeIfPresent([HouseholdMember].self, forKey: .householdMembers) ?? []
        dietaryRestrictions = try c.decodeIfPresent([DietaryRestriction].self, forKey: .dietaryRestrictions) ?? []
        myMember = try c.decodeIfPresent(HouseholdIdentityMember.self, forKey: .myMember)
        membership = try c.decodeIfPresent(MembershipInfo.self, forKey: .membership)
    }

    /// Set up: the household has a name and at least one person.
    var isOnboarded: Bool {
        !(profile?.householdName ?? "").trimmingCharacters(in: .whitespaces).isEmpty && !householdMembers.isEmpty
    }
}

/// `PUT /v1/bigtable/me`: the household's name, people and dietary restrictions.
nonisolated struct SaveHouseholdPayload: Encodable, Sendable {
    var householdName: String
    var avatarUrl: String?
    var householdMembers: [HouseholdMember]
    var dietaryRestrictions: [DietaryRestriction]
}

nonisolated struct SocialVisibilityResponse: Codable, Sendable {
    var socialProfileVisible: Bool
    var publishedRecipeCount: Int?
    var unpublishedRecipeCount: Int?
}

nonisolated enum InvitationStatus: String, Codable, Sendable {
    case pending, accepted, declined, cancelled
}

nonisolated struct HouseholdInvitationParty: Codable, Hashable, Sendable {
    var profileId: String
    var profileName: String?
    var avatarUrl: String?
}

nonisolated struct HouseholdInvitation: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var organizerProfileId: String
    var inviteeProfileId: String
    var status: InvitationStatus
    var createdAt: String
    var invitee: HouseholdInvitationParty?
    var organizer: HouseholdInvitationParty?
}

nonisolated struct HouseholdInvitationsResponse: Decodable, Sendable {
    var sent: [HouseholdInvitation]
    var received: [HouseholdInvitation]
}

nonisolated struct SendInvitationResponse: Decodable, Sendable { var invitation: HouseholdInvitation }

nonisolated struct InvitationActionResponse: Decodable, Sendable {
    var ok: Bool?
    var status: InvitationStatus
    var invitationId: String
}

nonisolated struct RemoveMemberResponse: Decodable, Sendable {
    var ok: Bool?
    /// "removed" or "left".
    var action: String
    var memberId: String
}

// MARK: - Social

nonisolated enum NotificationType: String, Codable, CaseIterable, Sendable {
    case recipePublished = "recipe_published"
    case recipeUpdated = "recipe_updated"
    case recipeLiked = "recipe_liked"
    case recipeSaved = "recipe_saved"
    case newFollower = "new_follower"
    case householdInvitation = "household_invitation"
    case householdInvitationAccepted = "household_invitation_accepted"
    case householdInvitationDeclined = "household_invitation_declined"
    case householdMemberRemoved = "household_member_removed"
    case householdMemberLeft = "household_member_left"
    case householdMemberPermissionsChanged = "household_member_permissions_changed"

    var settingLabel: String {
        switch self {
        case .recipePublished: "New recipes from people you follow"
        case .recipeUpdated: "Updates to recipes you saved"
        case .recipeLiked: "Likes on your recipes"
        case .recipeSaved: "Saves of your recipes"
        case .newFollower: "New followers"
        case .householdInvitation: "Household invitations"
        case .householdInvitationAccepted: "Invitations accepted"
        case .householdInvitationDeclined: "Invitations declined"
        case .householdMemberRemoved: "Removed from a household"
        case .householdMemberLeft: "Someone left your household"
        case .householdMemberPermissionsChanged: "Permission changes"
        }
    }
}

nonisolated struct NotificationRecord: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    /// Kept as a string so a type this build doesn't know still shows.
    var type: String
    var actorProfileId: String?
    var actorName: String?
    var actorAvatarUrl: String?
    var recipeId: String?
    var versionId: String?
    var data: [String: JSONValue]
    var readAt: String?
    var createdAt: String

    var kind: NotificationType? { NotificationType(rawValue: type) }
    var isUnread: Bool { readAt == nil }

    enum CodingKeys: String, CodingKey { case id, type, actorProfileId, actorName, actorAvatarUrl, recipeId, versionId, data, readAt, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        actorProfileId = try c.decodeIfPresent(String.self, forKey: .actorProfileId)
        actorName = try c.decodeIfPresent(String.self, forKey: .actorName)
        actorAvatarUrl = try c.decodeIfPresent(String.self, forKey: .actorAvatarUrl)
        recipeId = try c.decodeIfPresent(String.self, forKey: .recipeId)
        versionId = try c.decodeIfPresent(String.self, forKey: .versionId)
        data = try c.decodeIfPresent([String: JSONValue].self, forKey: .data) ?? [:]
        readAt = try c.decodeIfPresent(String.self, forKey: .readAt)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }
}

nonisolated struct NotificationsResponse: Decodable, Sendable {
    var notifications: [NotificationRecord]
    var pagination: Pagination?
}

nonisolated struct UnreadCountResponse: Decodable, Sendable { var unreadCount: Int }

nonisolated struct NotificationPrefsResponse: Codable, Sendable {
    var notificationPrefs: [String: Bool]
}

nonisolated enum FollowMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case following, followers, discover
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

nonisolated struct FollowProfile: Decodable, Hashable, Sendable, Identifiable {
    var profileId: String
    var followedAt: String?
    var profileName: String?
    var avatarUrl: String?
    var joinedAt: String?
    var isFollowing: Bool?
    var followerCount: Int?
    var followingCount: Int?
    var publishedRecipeCount: Int?

    var id: String { profileId }
}

nonisolated struct FollowsResponse: Decodable, Sendable {
    var mode: FollowMode
    var profiles: [FollowProfile]
    var pagination: Pagination?
}

nonisolated struct PublicRecipe: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var description: String?
    var imageUrl: String?
    var publishedAt: String?
    var likeCount: Int
}

nonisolated struct PublicProfile: Decodable, Hashable, Sendable {
    var profileId: String
    var profileName: String?
    var avatarUrl: String?
    var joinedAt: String?
    var followerCount: Int
    var followingCount: Int
}

nonisolated struct SocialProfileDetailResponse: Decodable, Sendable {
    var profile: PublicProfile
    var recipes: [PublicRecipe]
}

nonisolated struct BlockedProfilesResponse: Decodable, Sendable { var blockedProfileIds: [String] }

nonisolated struct PushTokensResponse: Decodable, Sendable {
    nonisolated struct Token: Decodable, Sendable { var token: String; var platform: String?; var updatedAt: String? }
    var tokens: [Token]
}

// MARK: - AI and usage

nonisolated struct UsageCheckResponse: Decodable, Hashable, Sendable {
    /// "free" or "pro".
    var tier: String
    var requestsUsed: Int
    var requestsLimit: Int
    var resetsAt: String
    var canMakeRequest: Bool
    var mealPlanCount: Int?
    var groceryListCount: Int?
    var creditsCharged: Int?
    var requestedCredits: Int?

    var isPro: Bool { tier == "pro" }
    /// Pro's limit is effectively unlimited (a million).
    var isUnlimited: Bool { requestsLimit >= 100_000 }
    var remaining: Int { max(0, requestsLimit - requestsUsed) }
}

nonisolated enum MealStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case comfort, varied, light
    var id: String { rawValue }
    var label: String {
        switch self {
        case .comfort: "Comfort food"
        case .varied: "Mix it up"
        case .light: "Lighter"
        }
    }
}

/// How the AI planner splits picks between your recipes, favorites and everything else
/// (percentages that add to 100).
nonisolated struct RecipeMix: Codable, Hashable, Sendable {
    var mine: Int
    var favorites: Int
    var other: Int

    static let balanced = RecipeMix(mine: 34, favorites: 33, other: 33)
}

/// `POST /v1/bigtable/ai/meal-plan`.
nonisolated struct MealPlanRequest: Encodable, Sendable {
    var prompt: String
    var mealStyle: MealStyle
    var recipeMix: RecipeMix?
    var quickTags: [String]
    /// Per day of the week, which slots to fill: { "thursday": ["dinner"] } (as the Expo app
    /// sends it and the API reads it).
    var selectedMeals: [String: [String]]?
    var weekStart: String?
    var selectedDates: [String]?
    var startDate: String?
    var endDate: String?
    var overwriteExisting: Bool?
    var previewOnly: Bool?
    /// Sent back with previewOnly false to save exactly the plan that was previewed.
    var generatedPlan: [String: [String: String]]?
    var generatedBy: String?
}

nonisolated struct MealPlanResponse: Decodable, Sendable {
    var planner: PlannerResponse?
    var previewPlanner: PlannerResponse?
    var generatedPlan: [String: [String: String]]?
    var generatedBy: String
    var usage: UsageCheckResponse
}

// MARK: - Grocery

nonisolated struct GroceryItem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var quantity: String
    var meals: [String]
    var bulk: Bool

    init(id: String = UUID().uuidString, name: String, quantity: String, meals: [String] = [], bulk: Bool = false) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.meals = meals
        self.bulk = bulk
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        quantity = try c.decodeIfPresent(String.self, forKey: .quantity) ?? ""
        meals = try c.decodeIfPresent([String].self, forKey: .meals) ?? []
        bulk = try c.decodeIfPresent(Bool.self, forKey: .bulk) ?? false
    }
}

nonisolated struct GrocerySection: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var icon: String
    var items: [GroceryItem]

    var id: String { name }
}

nonisolated enum GrocerySource: String, Codable, Sendable {
    case anthropic, fallback, manual
}

nonisolated struct GrocerySnapshot: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var generatedAtIso: String
    var itemCount: Int
    var estimatedCost: Double
    var source: GrocerySource
    var sections: [GrocerySection]
    var checks: [String: Bool]
}

nonisolated struct GrocerySnapshotsResponse: Decodable, Sendable {
    var snapshots: [GrocerySnapshot]
    var activeSnapshotId: String?
}

/// `PUT /v1/bigtable/grocery/snapshots`. Household members may only send `id` and `checks`.
nonisolated struct SaveGrocerySnapshotPayload: Encodable, Sendable {
    var id: String?
    var sections: [GrocerySection]?
    var checks: [String: Bool]
    var estimatedCost: Double?
    var source: GrocerySource?
    var makeActive: Bool?
}

nonisolated struct SaveGrocerySnapshotResponse: Decodable, Sendable { var snapshot: GrocerySnapshot }

/// `POST /v1/bigtable/ai/grocery-list`.
nonisolated struct GroceryListRequest: Encodable, Sendable {
    var costcoMode: Bool?
    var weekStart: String?
    var selectedDates: [String]?
    var startDate: String?
    var endDate: String?
    var overwriteExisting: Bool?
    var additionalPrompt: String?
}

nonisolated struct GroceryListResponse: Decodable, Sendable {
    nonisolated struct List: Decodable, Sendable { var sections: [GrocerySection]; var estimatedCost: Double }
    var groceryList: List
    var generatedBy: String
    var usage: UsageCheckResponse
}

// MARK: - Places

/// `GET /v1/bigtable/places/search`: restaurants for Dine Out.
nonisolated struct PlaceResult: Decodable, Hashable, Sendable, Identifiable {
    var key: String
    var name: String
    var address: String
    var phone: String?
    var logoUrl: String?
    var latitude: Double
    var longitude: Double
    var sourceClass: String?
    var sourceType: String?
    var website: String?

    var id: String { key }
}

nonisolated struct PlacesResponse: Decodable, Sendable { var results: [PlaceResult] }

// MARK: - Dates

/// The API's dates are local calendar days as "YYYY-MM-DD".
nonisolated enum ISODay {
    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    static func date(from string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The Sunday that starts the week containing `date` (the API's `weekStart`).
    static func weekStart(containing date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)  // 1 = Sunday
        let sunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: day) ?? day
        return string(from: sunday, calendar: calendar)
    }

    static func adding(days: Int, to string: String, calendar: Calendar = .current) -> String {
        guard let date = Self.date(from: string, calendar: calendar),
              let next = calendar.date(byAdding: .day, value: days, to: date) else { return string }
        return Self.string(from: next, calendar: calendar)
    }

    /// Parses the API's ISO-8601 timestamps, with or without fractional seconds.
    static func timestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
