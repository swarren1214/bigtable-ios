import Foundation
import OSLog

/// What went wrong talking to the BigTable API, in terms the app can act on.
nonisolated struct APIError: Error, LocalizedError, Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable { case offline, timedOut, signedOut, server, rejected }

    var kind: Kind
    var status: Int
    var code: String?
    /// The server's own message ("A Pro subscription is required…"), when it sent one.
    var message: String?

    static let offline = APIError(kind: .offline, status: 0)
    static let timedOut = APIError(kind: .timedOut, status: 408)
    static let signedOut = APIError(kind: .signedOut, status: 401)

    /// Over the free AI allowance, or the household organizer hasn't allowed it.
    /// The AI endpoints answer 403 with code LIMIT_REACHED when the free allowance is used up.
    var isLimitReached: Bool { status == 402 || status == 429 || code == "LIMIT_REACHED" || code == "USAGE_LIMIT_REACHED" }
    var isForbidden: Bool { status == 403 }

    var errorDescription: String? {
        switch kind {
        case .offline: "You appear to be offline. Connect to the internet and try again."
        case .timedOut: "This is taking longer than expected. Try again in a moment."
        case .signedOut: "Your session expired. Sign in again."
        case .server: "Something went wrong on our side. Try again shortly."
        case .rejected:
            if let message, !message.trimmingCharacters(in: .whitespaces).isEmpty { message }
            else { "Something went wrong. Try again." }
        }
    }
}

/// Talks to BigTable's routes on the shared Hearth API (`/v1/bigtable/…`). Every call carries
/// the Supabase access token from `AuthClient`; a 401 refreshes the token once and retries.
nonisolated struct BigTableAPI: Sendable {
    static let shared = BigTableAPI()

    var baseURLs: [URL] = [AppConfig.apiBaseURL]
    var auth: AuthClient = .shared
    var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        // AI calls (meal plans, scans) can take most of a minute.
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "api")

    // MARK: - Me and the household

    func me() async throws -> MeResponse {
        try await get("/v1/bigtable/me", query: [URLQueryItem(name: "ts", value: String(Int(Date.now.timeIntervalSince1970 * 1000)))])
    }

    func saveHousehold(_ payload: SaveHouseholdPayload) async throws -> MeResponse {
        try await send("PUT", "/v1/bigtable/me", body: payload)
    }

    func markTutorialComplete() async throws {
        let _: OKResponse = try await send("PATCH", "/v1/bigtable/me", body: ["tutorialComplete": true])
    }

    func deleteAccount() async throws {
        let _: OKResponse = try await send("DELETE", "/v1/bigtable/me")
    }

    func householdInvitations() async throws -> HouseholdInvitationsResponse {
        try await get("/v1/bigtable/household/invitations")
    }

    func sendHouseholdInvitation(to profileId: String) async throws -> HouseholdInvitation {
        let response: SendInvitationResponse = try await send("POST", "/v1/bigtable/household/invitations", body: ["inviteeProfileId": profileId])
        return response.invitation
    }

    func respondToInvitation(_ id: String, accept: Bool) async throws -> InvitationActionResponse {
        try await send("PUT", "/v1/bigtable/household/invitations/\(id.pathEscaped)", body: ["action": accept ? "accept" : "decline"])
    }

    func cancelInvitation(_ id: String) async throws -> InvitationActionResponse {
        try await send("PUT", "/v1/bigtable/household/invitations/\(id.pathEscaped)", body: ["action": "cancel"])
    }

    func memberPermissions(_ memberId: String) async throws -> HouseholdMemberPermissions {
        try await get("/v1/bigtable/household/members/\(memberId.pathEscaped)/permissions")
    }

    func saveMemberPermissions(_ memberId: String, _ permissions: HouseholdMemberPermissions) async throws {
        let _: OKResponse = try await send("PATCH", "/v1/bigtable/household/members/\(memberId.pathEscaped)/permissions", body: permissions)
    }

    /// The organizer removing someone, or someone leaving (their own id).
    func removeHouseholdMember(_ memberId: String) async throws -> RemoveMemberResponse {
        try await send("DELETE", "/v1/bigtable/household/members/\(memberId.pathEscaped)")
    }

    func sendAppInvitation(email: String) async throws {
        let _: OKResponse = try await send("POST", "/v1/bigtable/invite", body: ["email": email])
    }

    // MARK: - Plan

    func currentPlan(weekStart: String?) async throws -> PlannerResponse {
        try await get("/v1/bigtable/plans/current", query: weekStart.map { [URLQueryItem(name: "weekStart", value: $0)] } ?? [])
    }

    func updateSlot(_ update: PlanSlotUpdate) async throws -> PlannerSlotUpdateResponse {
        try await send("PUT", "/v1/bigtable/plans/current", body: update)
    }

    func searchPlaces(_ query: String, latitude: Double, longitude: Double, radiusMiles: Double = 5) async throws -> [PlaceResult] {
        let response: PlacesResponse = try await get("/v1/bigtable/places/search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "radiusMiles", value: String(radiusMiles)),
        ])
        return response.results
    }

    // MARK: - Recipes

    /// `collection`: nil for everything, "my" for the household's own, "removed" for deleted.
    func recipes(query: String? = nil, quickFilter: String? = nil, collection: String? = nil, limit: Int = 20, offset: Int = 0) async throws -> RecipeListResponse {
        var items = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty { items.append(URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespaces))) }
        if let quickFilter, quickFilter != "All", !quickFilter.isEmpty { items.append(URLQueryItem(name: "quickFilter", value: quickFilter)) }
        if let collection { items.append(URLQueryItem(name: "collection", value: collection)) }
        return try await get("/v1/bigtable/recipes", query: items)
    }

    func favoriteRecipes() async throws -> RecipeListResponse {
        try await get("/v1/bigtable/recipes/favorites")
    }

    func setFavorite(_ recipeId: String, saved: Bool) async throws {
        let _: OKResponse = try await send("PUT", "/v1/bigtable/recipes/favorites", body: FavoriteBody(recipeId: recipeId, saved: saved))
    }

    func recipe(_ id: String, versionId: String? = nil) async throws -> RecipeDetail {
        let response: RecipeDetailResponse = try await get("/v1/bigtable/recipes/\(id.pathEscaped)", query: versionId.map { [URLQueryItem(name: "versionId", value: $0)] } ?? [])
        return response.recipe
    }

    func createRecipe(_ payload: RecipePayload) async throws -> String {
        var numbered = payload
        // The Expo app numbered steps "1. …" before saving; keep doing it so both apps agree.
        numbered.instructions = payload.instructions?.enumerated().map { index, step in
            let stripped = step.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression)
            return "\(index + 1). \(stripped)"
        }
        let response: CreateRecipeResponse = try await send("POST", "/v1/bigtable/recipes", body: numbered)
        return response.id
    }

    func updateRecipe(_ id: String, _ payload: RecipePayload) async throws {
        let _: OKResponse = try await send("PATCH", "/v1/bigtable/recipes/\(id.pathEscaped)", body: payload)
    }

    func deleteRecipe(_ id: String) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/bigtable/recipes/\(id.pathEscaped)")
    }

    func deletedRecipes() async throws -> RecipeListResponse {
        try await get("/v1/bigtable/recipes", query: [URLQueryItem(name: "collection", value: "removed")])
    }

    func restoreRecipe(_ id: String) async throws {
        let _: OKResponse = try await send("POST", "/v1/bigtable/recipes/\(id.pathEscaped)/restore")
    }

    func publishRecipe(_ id: String) async throws -> PublishRecipeResponse {
        try await send("POST", "/v1/bigtable/recipes/\(id.pathEscaped)/publish")
    }

    func unpublishRecipe(_ id: String) async throws -> PublishRecipeResponse {
        try await send("POST", "/v1/bigtable/recipes/\(id.pathEscaped)/unpublish")
    }

    /// Copies a kitchen recipe to the server under its own id and publishes it (or updates the
    /// published copy).
    func putPublication(_ id: String, _ payload: RecipePayload) async throws -> PublishRecipeResponse {
        try await send("PUT", "/v1/bigtable/recipes/\(id.pathEscaped)/publication", body: payload)
    }

    /// Stops publishing a recipe. The server keeps the row so other families' plans still work.
    func unpublishPublication(_ id: String) async throws -> PublishRecipeResponse {
        try await send("DELETE", "/v1/bigtable/recipes/\(id.pathEscaped)/publication")
    }

    // MARK: - Household (subscription sharing)

    /// The organizer's join code, kept (encrypted) in the Hearth household so the family can
    /// join their subscription.
    func householdJoinCode(rotate: Bool = false) async throws -> String {
        let response: JoinCodeResponse = try await send("POST", "/v1/bigtable/household/join-code", body: ["rotate": rotate])
        return response.code
    }

    /// Joins the organizer's membership (their Pro plan) with the code from the household.
    func joinHousehold(code: String) async throws -> String {
        let response: JoinHouseholdResponse = try await send("POST", "/v1/bigtable/household/join", body: ["code": code])
        return response.organizerProfileId
    }

    /// The name shown on recipes this person publishes.
    func setDisplayName(_ name: String?) async throws {
        let _: DisplayNameResponse = try await send("PUT", "/v1/bigtable/me/public-profile", body: DisplayNameBody(displayName: name))
    }

    // MARK: - The move to iCloud

    func kitchenExport() async throws -> KitchenExport {
        try await get("/v1/bigtable/me/kitchen-export")
    }

    func markKitchenMoved() async throws {
        let _: KitchenMovedResponse = try await send("POST", "/v1/bigtable/me/kitchen-moved")
    }

    func likeState(_ id: String) async throws -> Bool {
        let response: RecipeLikeStateResponse = try await get("/v1/bigtable/recipes/\(id.pathEscaped)/like")
        return response.liked
    }

    func setLike(_ id: String, liked: Bool) async throws {
        let _: OKResponse = try await send("PUT", "/v1/bigtable/recipes/\(id.pathEscaped)/like", body: ["liked": liked])
    }

    func customTags() async throws -> [CustomTag] {
        let response: CustomTagsResponse = try await get("/v1/bigtable/recipes/tags")
        return response.tags
    }

    func createTag(_ label: String) async throws -> CustomTag {
        let response: CustomTagResponse = try await send("POST", "/v1/bigtable/recipes/tags", body: ["label": label])
        return response.tag
    }

    func renameTag(_ id: String, to label: String) async throws -> CustomTag {
        let response: CustomTagResponse = try await send("PATCH", "/v1/bigtable/recipes/tags/\(id.pathEscaped)", body: ["label": label])
        return response.tag
    }

    func deleteTag(_ id: String) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/bigtable/recipes/tags/\(id.pathEscaped)")
    }

    // MARK: - Recipe AI

    func generateRecipeImage(title: String, description: String?, tags: [String], ingredients: [String], instructions: [String]) async throws -> GenerateRecipeImageResponse {
        try await send("POST", "/v1/bigtable/ai/recipe-image", body: RecipeImageBody(title: title, description: description, tags: tags, ingredients: ingredients, instructions: instructions))
    }

    /// Photos of a cookbook page or recipe card, as JPEG.
    func scanRecipe(images: [Data]) async throws -> ScanRecipeDocumentResponse {
        let body = ScanBody(images: images.map { ScanBody.Image(dataBase64: $0.base64EncodedString(), mimeType: "image/jpeg") })
        return try await send("POST", "/v1/bigtable/ai/recipe-scan", body: body)
    }

    func recipeFromAudio(_ data: Data, mimeType: String = "audio/m4a") async throws -> GeneratedRecipeResponse {
        try await send("POST", "/v1/bigtable/ai/recipe-audio", body: ["dataBase64": data.base64EncodedString(), "mimeType": mimeType])
    }

    func recipeFromTranscript(_ transcript: String) async throws -> GeneratedRecipeResponse {
        try await send("POST", "/v1/bigtable/ai/recipe-transcript", body: ["transcript": transcript])
    }

    /// Changes a recipe (written out as text) the way the cook asked, or writes one from the
    /// request when `recipe` is empty. The response carries a short `reply`.
    func refineRecipe(_ recipe: String, request: String) async throws -> GeneratedRecipeResponse {
        try await send("POST", "/v1/bigtable/ai/recipe-refine", body: ["recipe": recipe, "request": request])
    }

    func recipeFromURL(_ url: String) async throws -> GeneratedRecipeResponse {
        try await send("POST", "/v1/bigtable/ai/recipe-url", body: ["url": url])
    }

    // MARK: - Plan and grocery AI

    func usage() async throws -> UsageCheckResponse {
        try await get("/v1/bigtable/usage/check")
    }

    func generateMealPlan(_ request: MealPlanRequest) async throws -> MealPlanResponse {
        try await send("POST", "/v1/bigtable/ai/meal-plan", body: request)
    }

    func generateGroceryList(_ request: GroceryListRequest) async throws -> GroceryListResponse {
        try await send("POST", "/v1/bigtable/ai/grocery-list", body: request)
    }

    func grocerySnapshots() async throws -> GrocerySnapshotsResponse {
        try await get("/v1/bigtable/grocery/snapshots")
    }

    func saveGrocerySnapshot(_ payload: SaveGrocerySnapshotPayload) async throws -> GrocerySnapshot {
        let response: SaveGrocerySnapshotResponse = try await send("PUT", "/v1/bigtable/grocery/snapshots", body: payload)
        return response.snapshot
    }

    // MARK: - Social

    func follows(_ mode: FollowMode, limit: Int = 30, offset: Int = 0) async throws -> FollowsResponse {
        try await get("/v1/bigtable/follows", query: [
            URLQueryItem(name: "mode", value: mode.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
    }

    func setFollowing(_ profileId: String, following: Bool) async throws {
        let _: OKResponse = try await send("PUT", "/v1/bigtable/follows", body: FollowBody(followeeProfileId: profileId, following: following))
    }

    func publicProfile(_ profileId: String) async throws -> SocialProfileDetailResponse {
        try await get("/v1/bigtable/profiles/\(profileId.pathEscaped)/public")
    }

    func blockedProfiles() async throws -> [String] {
        let response: BlockedProfilesResponse = try await get("/v1/bigtable/blocks")
        return response.blockedProfileIds
    }

    func block(_ profileId: String) async throws {
        let _: OKResponse = try await send("POST", "/v1/bigtable/blocks", body: ["blockedProfileId": profileId])
    }

    func unblock(_ profileId: String) async throws {
        let _: OKResponse = try await send("DELETE", "/v1/bigtable/blocks/\(profileId.pathEscaped)")
    }

    func socialVisibility() async throws -> SocialVisibilityResponse {
        try await get("/v1/bigtable/me/social-visibility")
    }

    func setSocialVisibility(_ visible: Bool) async throws -> SocialVisibilityResponse {
        try await send("PUT", "/v1/bigtable/me/social-visibility", body: ["socialProfileVisible": visible])
    }

    // MARK: - Notifications

    func notifications(limit: Int = 30, offset: Int = 0, unreadOnly: Bool = false) async throws -> NotificationsResponse {
        var items = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if unreadOnly { items.append(URLQueryItem(name: "unreadOnly", value: "true")) }
        return try await get("/v1/bigtable/notifications", query: items)
    }

    func markNotificationsRead(ids: [String]? = nil, all: Bool = false) async throws {
        let _: OKResponse = try await send("PATCH", "/v1/bigtable/notifications", body: MarkReadBody(markAllRead: all ? true : nil, ids: ids, markUnread: nil))
    }

    func markNotificationsUnread(ids: [String]) async throws {
        let _: OKResponse = try await send("PATCH", "/v1/bigtable/notifications", body: MarkReadBody(markAllRead: nil, ids: ids, markUnread: true))
    }

    func unreadNotificationCount() async throws -> Int {
        let response: UnreadCountResponse = try await get("/v1/bigtable/notifications/unread-count")
        return response.unreadCount
    }

    func notificationPrefs() async throws -> [String: Bool] {
        let response: NotificationPrefsResponse = try await get("/v1/bigtable/me/notification-prefs")
        return response.notificationPrefs
    }

    func setNotificationPrefs(_ prefs: [String: Bool]) async throws -> [String: Bool] {
        let response: NotificationPrefsResponse = try await send("PUT", "/v1/bigtable/me/notification-prefs", body: NotificationPrefsResponse(notificationPrefs: prefs))
        return response.notificationPrefs
    }

    func pushTokens() async throws -> PushTokensResponse {
        try await get("/v1/bigtable/push-tokens")
    }

    /// Registers this device's APNs token. The server sends through Expo's push service today,
    /// which only takes Expo tokens; native tokens are stored with platform "ios-apns" so the
    /// server can send to them once it talks to APNs directly (see the README).
    func registerPushToken(_ token: String, enabled: Bool) async throws {
        let _: OKResponse = try await send("PUT", "/v1/bigtable/push-tokens", body: PushBody(token: token, enabled: enabled, platform: "ios-apns"))
    }

    // MARK: - Request bodies

    nonisolated private struct FavoriteBody: Encodable { var recipeId: String; var saved: Bool }
    nonisolated private struct FollowBody: Encodable { var followeeProfileId: String; var following: Bool }
    nonisolated private struct MarkReadBody: Encodable { var markAllRead: Bool?; var ids: [String]?; var markUnread: Bool? }
    nonisolated private struct PushBody: Encodable { var token: String; var enabled: Bool; var platform: String }
    nonisolated private struct RecipeImageBody: Encodable {
        var title: String; var description: String?; var tags: [String]; var ingredients: [String]; var instructions: [String]
    }
    nonisolated private struct ScanBody: Encodable {
        nonisolated struct Image: Encodable { var dataBase64: String; var mimeType: String }
        var images: [Image]
    }

    // MARK: - Plumbing

    nonisolated private struct Empty: Encodable {}

    func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await perform(method: "GET", path: path, query: query, body: nil)
    }

    func send<T: Decodable & Sendable>(_ method: String, _ path: String) async throws -> T {
        try await perform(method: method, path: path, query: [], body: nil)
    }

    func send<T: Decodable & Sendable, Body: Encodable>(_ method: String, _ path: String, body: Body) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await perform(method: method, path: path, query: [], body: data)
    }

    private func perform<T: Decodable>(method: String, path: String, query: [URLQueryItem], body: Data?) async throws -> T {
        #if DEBUG
        // Screenshot mode: answered by the in-memory demo backend, never the network.
        if ScreenshotMode.isOn {
            let data = try ScreenshotBackend.shared.respond(method: method, path: path, query: query, body: body)
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                Self.log.error("Screenshot mode couldn't decode \(path, privacy: .public): \(String(describing: error), privacy: .public)")
                throw APIError(kind: .server, status: 500, code: "DECODE_FAILED")
            }
        }
        #endif
        var token: String
        do {
            token = try await auth.accessToken()
        } catch {
            throw APIError.signedOut
        }
        do {
            return try await attempt(method: method, path: path, query: query, body: body, token: token)
        } catch let error as APIError where error.kind == .signedOut {
            // The token was rejected (revoked, or expired early): refresh once and retry.
            do {
                token = try await auth.accessToken(forceRefresh: true)
            } catch {
                throw APIError.signedOut
            }
            return try await attempt(method: method, path: path, query: query, body: body, token: token)
        }
    }

    private func attempt<T: Decodable>(method: String, path: String, query: [URLQueryItem], body: Data?, token: String) async throws -> T {
        var lastError = APIError(kind: .server, status: 503)
        for (index, base) in baseURLs.enumerated() {
            let isLast = index == baseURLs.count - 1
            var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { components.queryItems = query }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await urlSession.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                switch error.code {
                case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: throw APIError.offline
                case .timedOut: lastError = .timedOut
                default: lastError = APIError(kind: .server, status: 503)
                }
                if isLast { throw lastError }
                Self.log.notice("\(base.host() ?? "", privacy: .public) unreachable for \(path, privacy: .public); trying the fallback")
                continue
            }

            guard let http = response as? HTTPURLResponse else { throw APIError(kind: .server, status: 502) }
            if (200..<300).contains(http.statusCode) {
                do {
                    return try JSONDecoder().decode(T.self, from: data)
                } catch {
                    Self.log.error("Couldn't decode \(path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw APIError(kind: .server, status: 500, code: "DECODE_FAILED")
                }
            }

            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // Hearth API errors: { "error": { "code", "message", "requestId" } }, with any extra
            // details (such as a top-level "code" like LIMIT_REACHED) alongside.
            let errorObject = payload?["error"] as? [String: Any]
            let message = (errorObject?["message"] as? String) ?? (payload?["error"] as? String) ?? (payload?["message"] as? String)
            let code = payload?["code"] as? String
            Self.log.notice("\(method, privacy: .public) \(path, privacy: .public) → \(http.statusCode) \(code ?? "", privacy: .public)")
            if http.statusCode == 401 { throw APIError.signedOut }
            let error = APIError(kind: http.statusCode >= 500 ? .server : .rejected, status: http.statusCode, code: code, message: message)
            if http.statusCode >= 500, !isLast {
                lastError = error
                continue
            }
            throw error
        }
        throw lastError
    }
}

extension String {
    /// Escapes an id for use as one path segment.
    nonisolated var pathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}
