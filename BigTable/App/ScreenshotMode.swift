import Foundation
import SwiftUI

/// Screenshot mode, for marketing screenshots (scripts/screenshots.sh).
///
/// Launched with `-Screenshots`, BigTable is signed in as a demo organizer (never touching the
/// Keychain), answers every API call from an in-memory demo backend instead of the network
/// (`ScreenshotBackend`), is Pro without RevenueCat, and keeps the tour, the push prompt and
/// the review prompt out of the way. Adding `-Screen <name>` opens one screen (see `Screen`).
/// Debug builds only: Release ignores the arguments, so none of this can be reached in the
/// App Store build.
nonisolated enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()

    /// The screens the script captures, by the name passed after `-Screen`.
    nonisolated enum Screen: String, CaseIterable {
        case plan, recipes, recipe, grocery, aiplan, aipreview, community, cook, notifications, profile
    }

    static let screen: Screen? = {
        guard isOn else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-Screen"), arguments.indices.contains(index + 1) else { return nil }
        return Screen(rawValue: arguments[index + 1])
    }()

    /// The demo organizer.
    static let demoUserID = "screenshots-me"
    static let demoName = "Megan Calloway"
    static let demoEmail = "megan@example.com"
    static let householdName = "The Calloways"

    /// The recipe and the cook the `recipe` and `cook` screens open.
    static let featuredRecipeID = "r-lasagna"
    static let featuredCookID = "demo-delgado"

    /// The active grocery list, then last week's and the week before's (History).
    static let grocerySnapshotIDs = ["grocery-demo-current", "grocery-demo-last-week", "grocery-demo-two-weeks"]

    /// A session that never expires, so nothing asks Supabase to refresh it.
    static var session: AuthSession {
        AuthSession(
            accessToken: "screenshots",
            refreshToken: "screenshots",
            expiresAt: Date.distantFuture.timeIntervalSince1970,
            user: AuthUser(id: demoUserID, email: demoEmail, fullName: demoName)
        )
    }

    /// At launch, before anything reads them: the days each demo grocery list covers (the API
    /// doesn't store them; the device remembers them).
    @MainActor
    static func prepareLaunch() {
        guard isOn else { return }
        let defaults = UserDefaults.standard
        let thisWeek = ISODay.weekStart(containing: .now)
        var ranges = defaults.dictionary(forKey: SettingsKey.grocerySnapshotRanges) ?? [:]
        for (index, id) in grocerySnapshotIDs.enumerated() {
            let start = ISODay.adding(days: -7 * index, to: thisWeek)
            ranges[id] = "\(start)|\(ISODay.adding(days: 6, to: start))"
        }
        defaults.set(ranges, forKey: SettingsKey.grocerySnapshotRanges)
    }
}

extension View {
    /// Screenshot mode: opens the requested screen once the household has loaded. Does
    /// nothing otherwise.
    func screenshotStage(recipesPath: Binding<NavigationPath>, communityPath: Binding<NavigationPath>) -> some View {
        modifier(ScreenshotStage(recipesPath: recipesPath, communityPath: communityPath))
    }
}

private struct ScreenshotStage: ViewModifier {
    @Binding var recipesPath: NavigationPath
    @Binding var communityPath: NavigationPath
    @Environment(AppRouter.self) private var router

    /// Once per launch (the tab view can be rebuilt).
    private static var staged = false

    func body(content: Content) -> some View {
        if ScreenshotMode.isOn {
            content.task { await stage() }
        } else {
            content
        }
    }

    private func stage() async {
        guard !Self.staged else { return }
        Self.staged = true
        // Let the first screen settle before moving on from it.
        try? await Task.sleep(for: .milliseconds(400))
        guard let screen = ScreenshotMode.screen else { return }
        switch screen {
        case .plan:
            router.tab = .plan
        case .recipes:
            router.tab = .recipes
        case .recipe:
            router.tab = .recipes
            recipesPath.append(RecipeDetailRoute(id: ScreenshotMode.featuredRecipeID, versionID: nil))
        case .grocery:
            router.tab = .grocery
        case .aiplan, .aipreview:
            // AIPlanView fills in the request (and for aipreview, generates the preview).
            router.tab = .plan
            router.present(.aiPlan)
        case .community:
            router.tab = .community
        case .cook:
            router.tab = .community
            communityPath.append(CommunityProfileRoute(id: ScreenshotMode.featuredCookID))
        case .notifications:
            router.tab = .plan
            router.present(.notifications)
        case .profile:
            router.tab = .plan
            router.present(.profile)
        }
    }
}

/// A demo recipe's picture: its symbol on a warm gradient, drawn on the device. Demo recipes
/// carry `demo-art:<symbol>:<RRGGBB>:<RRGGBB>` as their image URL; `RecipePhoto` draws it in
/// screenshot mode.
struct ScreenshotArt: View {
    let symbol: String
    let top: Color
    let bottom: Color

    init?(url: String) {
        let parts = url.split(separator: ":").map(String.init)
        guard parts.count == 4, parts[0] == "demo-art",
              let top = UInt32(parts[2], radix: 16), let bottom = UInt32(parts[3], radix: 16) else { return nil }
        symbol = parts[1]
        self.top = Color(hex: top)
        self.bottom = Color(hex: bottom)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: side * 1.1, height: side * 1.1)
                    .offset(x: proxy.size.width * 0.3, y: -proxy.size.height * 0.3)
                Circle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: side * 0.8, height: side * 0.8)
                    .offset(x: -proxy.size.width * 0.35, y: proxy.size.height * 0.35)
                Image(systemName: symbol)
                    .font(.system(size: side * 0.4, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.93))
                    .shadow(color: Color.black.opacity(0.2), radius: side * 0.04, y: side * 0.02)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

#if DEBUG

// MARK: - Demo backend

/// Screenshot mode's stand-in for the BigTable API: `BigTableAPI` hands it every request and
/// decodes what it returns, so every store and screen runs its real code on demo data. Edits
/// (cooked, checks, favorites, follows, the AI planner) are kept in memory for the launch;
/// nothing reaches the network or the real household.
nonisolated final class ScreenshotBackend: @unchecked Sendable {
    static let shared = ScreenshotBackend()

    private let lock = NSLock()
    private var weeks: [String: [String: Any]] = [:]
    private var favorites: Set<String>
    private var following: Set<String>
    private var grocery: [[String: Any]]
    private var activeSnapshotID: String

    private init() {
        favorites = Set(ScreenshotDemo.recipes.filter(\.favorite).map(\.id))
        following = Set(ScreenshotDemo.cooks.filter(\.iFollow).map(\.id))
        grocery = ScreenshotDemo.grocerySnapshots()
        activeSnapshotID = ScreenshotMode.grocerySnapshotIDs[0]
    }

    /// The JSON the API would send for this request.
    func respond(method: String, path: String, query: [URLQueryItem], body: Data?) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        var params: [String: String] = [:]
        for item in query { params[item.name] = item.value ?? "" }
        var input: [String: Any] = [:]
        if let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            input = object
        }
        let json = try route(method: method, path: path, params: params, input: input)
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func route(method: String, path: String, params: [String: String], input: [String: Any]) throws -> [String: Any] {
        let ok: [String: Any] = ["ok": true]
        let isGet = method == "GET"
        var parts = path.split(separator: "/").map(String.init)
        if parts.first == "api" { parts.removeFirst() }
        let first = parts.first ?? ""
        let second = parts.count > 1 ? parts[1] : ""

        switch first {
        case "me":
            switch second {
            case "social-visibility":
                return ["socialProfileVisible": true, "publishedRecipeCount": ScreenshotDemo.myPublishedCount, "unpublishedRecipeCount": 0]
            case "notification-prefs":
                return ["notificationPrefs": ScreenshotDemo.notificationPrefs]
            default:
                if isGet || method == "PUT" { return ScreenshotDemo.me() }
                return ok
            }
        case "household":
            if second == "invitations" {
                if isGet { return ["sent": [Any](), "received": [Any]()] }
                if parts.count > 2 {
                    let action = input["action"] as? String ?? "cancel"
                    let status = action == "accept" ? "accepted" : action == "decline" ? "declined" : "cancelled"
                    return ["ok": true, "status": status, "invitationId": parts[2]]
                }
                let invitee = input["inviteeProfileId"] as? String ?? ""
                let invitation: [String: Any] = [
                    "id": "invitation-\(invitee)", "organizerProfileId": ScreenshotMode.demoUserID, "inviteeProfileId": invitee,
                    "status": "pending", "createdAt": ScreenshotDemo.iso(minutesAgo: 0),
                ]
                return ["invitation": invitation]
            }
            if second == "members", parts.count > 2 {
                if parts.count > 3 {
                    if isGet { return ScreenshotDemo.organizerPermissions }
                    return ok
                }
                return ["ok": true, "action": "removed", "memberId": parts[2]]
            }
        case "plans":
            if isGet { return week(params["weekStart"] ?? ScreenshotDemo.currentWeekStart) }
            return try updateSlot(input)
        case "places":
            let latitude = Double(params["latitude"] ?? "") ?? 37.3349
            let longitude = Double(params["longitude"] ?? "") ?? -122.0090
            return ["results": ScreenshotDemo.places(latitude: latitude, longitude: longitude)]
        case "recipes":
            return try recipes(method: method, parts: parts, params: params, input: input)
        case "usage":
            return ScreenshotDemo.usage
        case "ai":
            if second == "meal-plan" { return mealPlan(input) }
            if second == "grocery-list" { return groceryList() }
            throw APIError(kind: .rejected, status: 403, code: nil, message: "This isn't available in screenshot mode.")
        case "grocery":
            if isGet { return ["snapshots": grocery, "activeSnapshotId": activeSnapshotID] }
            return saveGrocery(input)
        case "follows":
            if isGet { return ScreenshotDemo.follows(mode: params["mode"] ?? "discover", following: following) }
            if let id = input["followeeProfileId"] as? String, let on = input["following"] as? Bool {
                if on { following.insert(id) } else { following.remove(id) }
            }
            return ok
        case "profiles":
            if let profile = ScreenshotDemo.publicProfile(second) { return profile }
        case "blocks":
            if isGet { return ["blockedProfileIds": [String]()] }
            return ok
        case "notifications":
            if second == "unread-count" { return ["unreadCount": ScreenshotDemo.unreadCount] }
            if isGet { return ScreenshotDemo.notifications(unreadOnly: params["unreadOnly"] == "true") }
            return ok
        case "push-tokens":
            if isGet { return ["tokens": [Any]()] }
            return ok
        case "invite":
            return ok
        default:
            break
        }
        throw APIError(kind: .rejected, status: 404, code: nil, message: "Not found.")
    }

    // MARK: Plan

    private func week(_ weekStart: String) -> [String: Any] {
        if let stored = weeks[weekStart] { return stored }
        let made = ScreenshotDemo.week(weekStart)
        weeks[weekStart] = made
        return made
    }

    /// `PUT /api/plans/current`: the fields sent replace the slot's (null clears one).
    private func updateSlot(_ input: [String: Any]) throws -> [String: Any] {
        guard let day = input["day"] as? String, let slotName = input["slot"] as? String else {
            throw APIError(kind: .rejected, status: 400, code: nil, message: "Missing day or slot.")
        }
        let weekStart = input["weekStart"] as? String ?? ScreenshotDemo.currentWeekStart
        var planner = week(weekStart)
        var days = planner["days"] as? [String: Any] ?? [:]
        var meals = days[day] as? [String: Any] ?? [:]
        var slot = meals[slotName] as? [String: Any] ?? ScreenshotDemo.emptySlot
        for key in ["customMeal", "dineOut", "recipeItems", "snackItems", "excludedMembers", "completed"] {
            if let value = input[key] { slot[key] = value }
        }
        meals[slotName] = slot
        days[day] = meals
        planner["days"] = days
        weeks[weekStart] = planner
        let planID = planner["planId"] as? String ?? "plan-\(weekStart)"
        return ["day": day, "slot": slotName, "weekStart": weekStart, "planId": planID, "slotData": slot]
    }

    /// `POST /api/ai/meal-plan`: fills the chosen meals from the demo recipes (keeping what's
    /// planned unless asked to replace it), as a preview or saved.
    private func mealPlan(_ input: [String: Any]) -> [String: Any] {
        let weekStart = input["weekStart"] as? String ?? ScreenshotDemo.currentWeekStart
        let selectedDates = (input["selectedDates"] as? [String] ?? []).sorted()
        let selectedMeals = input["selectedMeals"] as? [String: [String]] ?? [:]
        let overwrite = input["overwriteExisting"] as? Bool ?? true
        let previewOnly = input["previewOnly"] as? Bool ?? true
        let previewed = input["generatedPlan"] as? [String: [String: String]]
        var generated: [String: [String: String]] = previewed ?? [:]
        var counters: [String: Int] = [:]

        var planner = week(weekStart)
        var days = planner["days"] as? [String: Any] ?? [:]
        for iso in selectedDates {
            guard let date = ISODay.date(from: iso), ISODay.weekStart(containing: date) == weekStart else { continue }
            let dayName = ScreenshotDemo.dayNames[Calendar.current.component(.weekday, from: date) - 1]
            var meals = days[dayName] as? [String: Any] ?? [:]
            for slotName in selectedMeals[dayName] ?? [] {
                let existing = meals[slotName] as? [String: Any] ?? ScreenshotDemo.emptySlot
                if ScreenshotDemo.isFilled(existing) && !overwrite { continue }
                let recipeID: String
                if let previewed {
                    guard let title = previewed[dayName]?[slotName], let found = ScreenshotDemo.recipe(titled: title) else { continue }
                    recipeID = found.id
                } else {
                    let count = counters[slotName] ?? 0
                    counters[slotName] = count + 1
                    recipeID = ScreenshotDemo.suggestion(slot: slotName, index: count)
                    generated[dayName, default: [:]][slotName] = ScreenshotDemo.recipe(recipeID)?.title ?? recipeID
                }
                meals[slotName] = ScreenshotDemo.slot([ScreenshotDemo.item(recipeID, role: "entree")], completed: false)
            }
            days[dayName] = meals
        }
        planner["days"] = days

        var response: [String: Any] = ["generatedPlan": generated, "generatedBy": "anthropic", "usage": ScreenshotDemo.usage]
        if previewOnly {
            response["previewPlanner"] = planner
        } else {
            weeks[weekStart] = planner
            response["planner"] = planner
        }
        return response
    }

    // MARK: Recipes

    private func recipes(method: String, parts: [String], params: [String: String], input: [String: Any]) throws -> [String: Any] {
        let ok: [String: Any] = ["ok": true]
        let isGet = method == "GET"
        if parts.count == 1 {
            if isGet { return list(params) }
            return ["id": "recipe-\(UUID().uuidString.lowercased())"]
        }
        let second = parts[1]
        switch second {
        case "favorites":
            if isGet {
                let saved = ScreenshotDemo.recipes.filter { favorites.contains($0.id) }.map { $0.summary(isFavorite: true) }
                let pagination: [String: Any] = ["limit": saved.count, "offset": 0, "hasMore": false, "nextOffset": saved.count, "totalCount": saved.count]
                return ["recipes": saved, "pagination": pagination]
            }
            if let id = input["recipeId"] as? String, let saved = input["saved"] as? Bool {
                if saved { favorites.insert(id) } else { favorites.remove(id) }
            }
            return ok
        case "tags":
            if isGet { return ["tags": ScreenshotDemo.customTags] }
            if method == "DELETE" { return ok }
            let label = input["label"] as? String ?? "Tag"
            let tag: [String: Any] = ["id": parts.count > 2 ? parts[2] : "tag-\(label.lowercased())", "label": label, "normalized": label.lowercased()]
            return ["tag": tag]
        default:
            break
        }
        guard let recipe = ScreenshotDemo.recipe(second) else {
            throw APIError(kind: .rejected, status: 404, code: nil, message: "Recipe not found.")
        }
        if parts.count == 2 {
            if isGet { return ["recipe": recipe.detail(isFavorite: favorites.contains(recipe.id))] }
            return ok
        }
        switch parts[2] {
        case "like":
            if isGet { return ["liked": recipe.liked] }
            return ok
        case "publish", "unpublish":
            return ["ok": true, "recipeId": recipe.id, "versionId": recipe.versionID, "versionNumber": recipe.versionCount,
                    "status": parts[2] == "publish" ? "published" : "unpublished"]
        default:
            return ok
        }
    }

    /// `GET /api/recipes`: search, quick filter, collection and paging.
    private func list(_ params: [String: String]) -> [String: Any] {
        let query = (params["q"] ?? "").lowercased()
        let filter = (params["quickFilter"] ?? "").lowercased()
        let collection = params["collection"] ?? ""
        let limit = Int(params["limit"] ?? "") ?? 20
        let offset = Int(params["offset"] ?? "") ?? 0
        let matching = ScreenshotDemo.recipes.filter { recipe in
            if collection == "removed" { return false }
            if collection == "my" && !recipe.isMine { return false }
            if recipe.status != "published" && !recipe.isMine { return false }
            if !filter.isEmpty && filter != "all" && !recipe.tags.contains(filter) { return false }
            if !query.isEmpty && !recipe.matches(query) { return false }
            return true
        }
        let page = Array(matching.dropFirst(offset).prefix(limit))
        let pagination: [String: Any] = [
            "limit": limit, "offset": offset, "hasMore": offset + page.count < matching.count,
            "nextOffset": offset + page.count, "totalCount": matching.count,
        ]
        return ["recipes": page.map { $0.summary(isFavorite: favorites.contains($0.id)) }, "pagination": pagination]
    }

    // MARK: Grocery

    private func saveGrocery(_ input: [String: Any]) -> [String: Any] {
        let id = input["id"] as? String
        let fresh: [String: Any] = [
            "id": "grocery-\(UUID().uuidString.lowercased())", "generatedAtIso": ScreenshotDemo.iso(minutesAgo: 0),
            "source": "manual", "estimatedCost": 0.0, "sections": [Any](), "checks": [String: Bool](), "itemCount": 0,
        ]
        var snapshot = grocery.first(where: { ($0["id"] as? String) == id }) ?? fresh
        for key in ["sections", "checks", "estimatedCost", "source"] {
            if let value = input[key], !(value is NSNull) { snapshot[key] = value }
        }
        var count = 0
        for section in snapshot["sections"] as? [[String: Any]] ?? [] {
            count += (section["items"] as? [Any])?.count ?? 0
        }
        snapshot["itemCount"] = count
        let savedID = snapshot["id"] as? String ?? ""
        if let index = grocery.firstIndex(where: { ($0["id"] as? String) == savedID }) {
            grocery[index] = snapshot
        } else {
            grocery.insert(snapshot, at: 0)
        }
        if id == nil || input["makeActive"] as? Bool == true { activeSnapshotID = savedID }
        return ["snapshot": snapshot]
    }

    /// `POST /api/ai/grocery-list`: the demo week's list again.
    private func groceryList() -> [String: Any] {
        let current = grocery.first(where: { ($0["id"] as? String) == activeSnapshotID })
        let active: [String: Any] = current ?? grocery.first ?? [:]
        let list: [String: Any] = ["sections": active["sections"] ?? [Any](), "estimatedCost": active["estimatedCost"] ?? 0.0]
        return ["groceryList": list, "generatedBy": "anthropic", "usage": ScreenshotDemo.usage]
    }
}

// MARK: - Demo content

/// A recipe in the demo library.
nonisolated struct DemoRecipe: Sendable {
    var id: String
    var title: String
    var blurb: String
    /// `<symbol>:<RRGGBB>:<RRGGBB>` for `ScreenshotArt`.
    var art: String
    var prep: Int
    var cook: Int
    var serves: Int
    var difficulty: String
    var tags: [String]
    /// Who shared it (a `DemoCook` id), or nil for the demo household's own.
    var creator: String?
    var status: String
    var likes: Int
    var favorite: Bool
    var publishedDaysAgo: Double
    /// "amount|measurement|name".
    var ingredients: [String]
    var steps: [String]

    var isMine: Bool { creator == nil }
    var imageURL: String { "demo-art:\(art)" }
    var versionID: String { "v-\(id)" }
    var versionCount: Int { id == ScreenshotMode.featuredRecipeID ? 2 : 1 }
    var liked: Bool { favorite && !isMine }
    var creatorID: String { creator ?? ScreenshotMode.demoUserID }
    var creatorName: String { ScreenshotDemo.cooks.first(where: { $0.id == creator })?.name ?? ScreenshotMode.demoName }

    func matches(_ query: String) -> Bool {
        title.lowercased().contains(query) || blurb.lowercased().contains(query) || tags.contains { $0.contains(query) }
    }

    func summary(isFavorite: Bool) -> [String: Any] {
        var json: [String: Any] = [
            "id": id, "title": title, "description": blurb, "imageUrl": imageURL,
            "prepMinutes": prep, "cookMinutes": cook, "baseServings": serves, "difficulty": difficulty,
            "tags": tags, "sourceName": "user", "attributionRequired": false, "isFavorite": isFavorite,
            "isLiked": liked, "likeCount": likes, "createdByProfileId": creatorID, "creatorName": creatorName,
            "status": status, "hasUpdateAvailable": false,
        ]
        if status == "published" {
            json["currentVersionId"] = versionID
            json["publishedAt"] = ScreenshotDemo.iso(minutesAgo: publishedDaysAgo * 1440)
        }
        return json
    }

    func detail(isFavorite: Bool) -> [String: Any] {
        var json = summary(isFavorite: isFavorite)
        json["instructions"] = steps
        json["versionCount"] = versionCount
        var rows: [[String: Any]] = []
        for (index, line) in ingredients.enumerated() {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            var row: [String: Any] = ["id": "\(id)-ingredient-\(index)", "name": fields[2]]
            if let amount = Double(fields[0]) { row["amount"] = amount }
            if !fields[1].isEmpty { row["measurementType"] = fields[1] }
            rows.append(row)
        }
        json["ingredients"] = rows
        return json
    }
}

/// Another family on BigTable.
nonisolated struct DemoCook: Sendable {
    var id: String
    var name: String
    var joinedDaysAgo: Double
    var followers: Int
    var following: Int
    var recipeCount: Int
    var iFollow: Bool
    var followsMe: Bool
    var connectedDaysAgo: Double

    func followJSON(isFollowing: Bool) -> [String: Any] {
        [
            "profileId": id, "profileName": name, "followedAt": ScreenshotDemo.iso(minutesAgo: connectedDaysAgo * 1440),
            "joinedAt": ScreenshotDemo.iso(minutesAgo: joinedDaysAgo * 1440), "isFollowing": isFollowing,
            "followerCount": followers, "followingCount": following, "publishedRecipeCount": recipeCount,
        ]
    }
}

/// Someone in the demo household.
nonisolated struct DemoMember: Sendable {
    var name: String
    var dateOfBirth: String
    var likes: [String]
    var dislikes: [String]
}

/// Something in the demo inbox.
nonisolated struct DemoNotification: Sendable {
    var id: String
    var type: String
    var actorID: String
    var actorName: String
    var recipeID: String?
    var minutesAgo: Double
    var unread: Bool

    var json: [String: Any] {
        var data: [String: Any] = ["actorName": actorName]
        var record: [String: Any] = [
            "id": id, "type": type, "actorProfileId": actorID, "actorName": actorName,
            "createdAt": ScreenshotDemo.iso(minutesAgo: minutesAgo),
        ]
        if let recipeID, let recipe = ScreenshotDemo.recipe(recipeID) {
            record["recipeId"] = recipeID
            data["recipeTitle"] = recipe.title
        }
        if !unread { record["readAt"] = ScreenshotDemo.iso(minutesAgo: max(0, minutesAgo - 30)) }
        record["data"] = data
        return record
    }
}

/// The demo household, the Calloways (six of them): a week that's mostly planned with tonight's
/// dinner up next, a library of their own recipes and ones they follow, a grocery list half
/// shopped, other families in Community, and a few notifications. Invented names only.
nonisolated enum ScreenshotDemo {
    static let dayNames = DayOfWeek.allCases.map(\.rawValue)
    static var currentWeekStart: String { ISODay.weekStart(containing: .now) }
    static var todayIndex: Int { Calendar.current.component(.weekday, from: .now) - 1 }

    static func iso(minutesAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-minutesAgo * 60))
    }

    // MARK: Household

    static let members: [DemoMember] = [
        DemoMember(name: "Megan", dateOfBirth: "1987-04-12", likes: ["Thai food", "Roasted vegetables"], dislikes: ["Olives"]),
        DemoMember(name: "Dan", dateOfBirth: "1985-08-30", likes: ["Barbecue", "Spicy food"], dislikes: ["Mushrooms"]),
        DemoMember(name: "Ava", dateOfBirth: "2013-09-03", likes: ["Pasta", "Tacos"], dislikes: ["Salmon"]),
        DemoMember(name: "Owen", dateOfBirth: "2016-05-21", likes: ["Pancakes", "Chicken"], dislikes: ["Spinach"]),
        DemoMember(name: "Lily", dateOfBirth: "2019-11-08", likes: ["Fruit", "Mac and cheese"], dislikes: ["Onions"]),
        DemoMember(name: "Theo", dateOfBirth: "2022-02-14", likes: ["Blueberries"], dislikes: []),
    ]

    static func me() -> [String: Any] {
        let profile: [String: Any] = [
            "id": ScreenshotMode.demoUserID, "household_name": ScreenshotMode.householdName,
            "created_at": iso(minutesAgo: 400 * 1440), "social_profile_visible": true, "tutorial_complete": true,
        ]
        var people: [[String: Any]] = []
        for member in members {
            people.append([
                "id": "member-\(member.name.lowercased())", "name": member.name, "dateOfBirth": member.dateOfBirth,
                "likes": member.likes, "dislikes": member.dislikes,
            ])
        }
        let restrictions: [[String: Any]] = [["type": "child_1", "value": "Nut-Free"]]
        let myMember: [String: Any] = ["name": ScreenshotMode.demoName]
        let membership: [String: Any] = [
            "role": "organizer", "organizerProfileId": ScreenshotMode.demoUserID,
            "organizerHouseholdName": ScreenshotMode.householdName, "pendingInvitationCount": 0,
        ]
        return ["profile": profile, "householdMembers": people, "dietaryRestrictions": restrictions, "myMember": myMember, "membership": membership]
    }

    static var organizerPermissions: [String: Any] {
        ["canManageMealPlan": true, "canUseAiMealPlan": true, "canUseAiGrocery": true, "canEditMembers": true]
    }

    static var usage: [String: Any] {
        [
            "tier": "pro", "requestsUsed": 7, "requestsLimit": 1_000_000, "resetsAt": iso(minutesAgo: -12 * 1440),
            "canMakeRequest": true, "mealPlanCount": 4, "groceryListCount": 3,
        ]
    }

    static var notificationPrefs: [String: Bool] {
        var prefs: [String: Bool] = [:]
        for type in NotificationType.allCases { prefs[type.rawValue] = true }
        return prefs
    }

    static var myPublishedCount: Int { recipes.filter { $0.isMine && $0.status == "published" }.count }

    static var customTags: [[String: Any]] {
        [
            ["id": "tag-freezer", "label": "Freezer-friendly", "normalized": "freezer-friendly"],
            ["id": "tag-grandma", "label": "Grandma's", "normalized": "grandma's"],
        ]
    }

    // MARK: The week

    /// Sunday through Saturday of the current week: everything through today planned (and
    /// cooked, up to tonight's dinner), the next few days partly planned, a night out, and a
    /// few breakfasts and lunches left for the AI planner.
    static func week(_ weekStart: String) -> [String: Any] {
        var days: [String: Any] = [:]
        if weekStart == currentWeekStart {
            for (index, day) in dayNames.enumerated() {
                days[day] = meals(offset: index - todayIndex)
            }
        }
        return ["planId": "plan-\(weekStart)", "weekStart": weekStart, "days": days]
    }

    /// One day, `offset` days from today (negative: earlier this week).
    private static func meals(offset: Int) -> [String: Any] {
        let k = ((offset % 7) + 7) % 7
        var day: [String: Any] = [:]
        if offset < 3 { day["breakfast"] = slot([item(breakfasts[k], role: "entree")], completed: offset <= 0) }
        if offset < 2 { day["lunch"] = lunch(k, completed: offset <= 0) }
        day["dinner"] = dinner(k, completed: offset < 0)
        return day
    }

    private static let breakfasts = ["r-oats", "r-pancakes", "r-muffins", "r-frittata", "r-pancakes", "r-muffins", "r-frittata"]

    private static func lunch(_ k: Int, completed: Bool) -> [String: Any] {
        switch k {
        case 0: return slot([], custom: "Leftover turkey chili", snacks: demoSnacks, completed: completed)
        case 1: return slot([item("r-bowls", role: "entree")], excluded: ["Ava", "Owen"], completed: completed)
        case 2, 5: return slot([item("r-pinwheels", role: "entree")], completed: completed)
        case 3: return slot([], custom: "Grilled cheese and tomato soup", completed: completed)
        case 4: return slot([item("r-bowls", role: "entree")], completed: completed)
        default: return slot([], custom: "Leftovers", completed: completed)
        }
    }

    private static func dinner(_ k: Int, completed: Bool) -> [String: Any] {
        switch k {
        case 0: return slot([item("r-chicken", role: "entree"), item("r-greenbeans", role: "side")], completed: completed)
        case 1: return slot([item("r-salmon", role: "entree")], completed: completed)
        case 2: return slot([item("r-curry", role: "entree")], completed: completed)
        case 3: return slot([], dineOut: dineOut, completed: completed)
        case 4: return slot([item("r-lasagna", role: "entree"), item("r-greenbeans", role: "side"), item("r-cookies", role: "dessert")], completed: completed)
        case 5: return slot([item("r-chili", role: "entree")], completed: completed)
        default: return slot([item("r-fajitas", role: "entree"), item("r-cobbler", role: "dessert")], excluded: ["Dan"], completed: completed)
        }
    }

    private static var dineOut: [String: Any] {
        [
            "label": "Dine Out", "name": "Rosalita's Cantina", "address": "418 Maple Avenue, Springfield",
            "phone": "(555) 014-2290", "cuisine": "Mexican", "price": "$$", "hours": "11 AM – 10 PM",
        ]
    }

    private static var demoSnacks: [[String: Any]] {
        [
            ["offId": "demo-snack-apples", "description": "Honeycrisp Apple Slices", "servingSize": "1 bag (57 g)", "calories": 30],
            ["offId": "demo-snack-cheese", "description": "Cheddar Cheese Sticks", "servingSize": "1 stick (21 g)", "calories": 80],
        ]
    }

    static var emptySlot: [String: Any] {
        ["recipeItems": [Any](), "snackItems": [Any](), "excludedMembers": [String](), "completed": false]
    }

    /// A planned meal, with the first title as the custom meal (as the apps save it).
    static func slot(_ items: [[String: Any]], custom: String? = nil, dineOut: [String: Any]? = nil,
                     snacks: [[String: Any]] = [], excluded: [String] = [], completed: Bool) -> [String: Any] {
        var json: [String: Any] = ["recipeItems": items, "snackItems": snacks, "excludedMembers": excluded, "completed": completed]
        if let title = custom ?? (items.first?["title"] as? String) { json["customMeal"] = title }
        if let dineOut { json["dineOut"] = dineOut }
        return json
    }

    static func item(_ id: String, role: String) -> [String: Any] {
        guard let found = recipe(id) else { return ["title": id, "role": role, "source": "custom"] }
        return [
            "title": found.title, "role": role, "imageUrl": found.imageURL, "recipeId": found.id,
            "recipeVersionId": found.versionID, "source": "library", "recipeStatus": found.status,
            "currentVersionId": found.versionID, "hasUpdateAvailable": false,
        ]
    }

    static func isFilled(_ slot: [String: Any]) -> Bool {
        if let items = slot["recipeItems"] as? [Any], !items.isEmpty { return true }
        if let custom = slot["customMeal"] as? String, !custom.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if let dineOut = slot["dineOut"], !(dineOut is NSNull) { return true }
        return false
    }

    /// What the AI planner picks for an empty meal, in turn.
    static func suggestion(slot: String, index: Int) -> String {
        let pool: [String]
        switch slot {
        case "breakfast": pool = ["r-frittata", "r-muffins", "r-pancakes", "r-oats"]
        case "lunch": pool = ["r-bowls", "r-pinwheels", "r-tortellini"]
        default: pool = ["r-meatballs", "r-stirfry", "r-tortellini", "r-soup", "r-enchiladas", "r-sliders"]
        }
        return pool[index % pool.count]
    }

    static func places(latitude: Double, longitude: Double) -> [[String: Any]] {
        let spots: [(name: String, address: String, dLat: Double, dLon: Double)] = [
            ("Rosalita's Cantina", "418 Maple Avenue, Springfield", 0.004, 0.006),
            ("Bramble & Rye Pizza Co.", "92 Orchard Street, Springfield", -0.006, 0.003),
            ("Golden Lotus Noodle House", "1550 Harbor Boulevard, Springfield", 0.009, -0.007),
        ]
        var results: [[String: Any]] = []
        for (index, spot) in spots.enumerated() {
            results.append([
                "key": "demo-place-\(index)", "name": spot.name, "address": spot.address,
                "latitude": latitude + spot.dLat, "longitude": longitude + spot.dLon,
            ])
        }
        return results
    }

    // MARK: Recipes

    static func recipe(_ id: String) -> DemoRecipe? { recipes.first(where: { $0.id == id }) }
    static func recipe(titled title: String) -> DemoRecipe? { recipes.first(where: { $0.title == title }) }

    static let recipes: [DemoRecipe] = [
        DemoRecipe(
            id: "r-lasagna", title: "Big-Batch Sausage Lasagna",
            blurb: "Two pans' worth of layers: one for tonight and one for the freezer. Sweet Italian sausage, a ricotta-spinach layer and plenty of mozzarella.",
            art: "oven.fill:E0533A:8E2418", prep: 30, cook: 75, serves: 12, difficulty: "medium",
            tags: ["dinner", "pork", "italian"], creator: nil, status: "published", likes: 112, favorite: true, publishedDaysAgo: 64,
            ingredients: [
                "2|lb|sweet Italian sausage, casings removed", "1|each|yellow onion, diced", "4|clove|garlic, minced",
                "2|jar|marinara sauce (24 oz)", "1|can|crushed tomatoes (28 oz)", "2|tsp|dried basil", "30||lasagna noodles",
                "2|lb|whole-milk ricotta", "2|each|large eggs", "10|oz|frozen spinach, thawed and squeezed dry",
                "1|cup|grated Parmesan", "2|lb|shredded mozzarella",
            ],
            steps: [
                "Heat the oven to 375°F. Cook the noodles in salted water until just shy of tender, then lay them flat on oiled sheet pans.",
                "Brown the sausage with the onion in a large pot, breaking it up, about 10 minutes. Add the garlic for the last minute.",
                "Stir in the marinara, crushed tomatoes and basil and simmer 15 minutes while you make the filling.",
                "Mix the ricotta, eggs, spinach and half the Parmesan with a good pinch of salt.",
                "In two 9x13 pans, layer sauce, noodles, ricotta and mozzarella; repeat twice, finishing with sauce, mozzarella and the rest of the Parmesan.",
                "Cover with foil and bake 45 minutes, then uncover and bake 20 more until bubbling and browned. Rest 15 minutes before cutting.",
                "To freeze the second pan, cool it, wrap it well and freeze for up to 3 months. Bake from thawed, covered, for an hour.",
            ]
        ),
        DemoRecipe(
            id: "r-chicken", title: "Honey-Garlic Chicken Thighs",
            blurb: "Sticky, garlicky and done in one pan. The kids ask for this one by name.",
            art: "flame.fill:E8A33D:A1461F", prep: 10, cook: 30, serves: 8, difficulty: "easy",
            tags: ["dinner", "chicken", "gluten-free"], creator: nil, status: "published", likes: 48, favorite: true, publishedDaysAgo: 120,
            ingredients: [
                "4|lb|bone-in chicken thighs", "0.33|cup|honey", "0.25|cup|tamari or soy sauce", "6|clove|garlic, minced",
                "2|tbsp|rice vinegar", "1|tsp|smoked paprika", "1|tbsp|olive oil", "2|each|green onions, sliced",
            ],
            steps: [
                "Heat the oven to 425°F. Pat the chicken dry and season with salt, pepper and the paprika.",
                "Sear skin-side down in the oil in a large oven-safe skillet until golden, about 6 minutes, then flip.",
                "Whisk the honey, tamari, garlic and vinegar and pour it around the chicken.",
                "Roast 20 to 25 minutes, basting once, until the chicken reaches 175°F and the sauce is sticky.",
                "Scatter the green onions over and spoon the pan sauce on top.",
            ]
        ),
        DemoRecipe(
            id: "r-greenbeans", title: "Lemon Parmesan Green Beans",
            blurb: "The side dish that disappears first.",
            art: "leaf.fill:7DBB5A:2D6A3A", prep: 5, cook: 12, serves: 8, difficulty: "easy",
            tags: ["side", "vegetarian", "gluten-free"], creator: nil, status: "published", likes: 21, favorite: false, publishedDaysAgo: 98,
            ingredients: ["2|lb|green beans, trimmed", "2|tbsp|olive oil", "3|clove|garlic, sliced", "1|each|lemon, zested and juiced", "0.5|cup|grated Parmesan"],
            steps: [
                "Heat the oven to 425°F.",
                "Toss the beans with the oil, garlic, salt and pepper on a sheet pan.",
                "Roast 12 minutes, tossing once, until blistered.",
                "Finish with the lemon zest, a squeeze of juice and the Parmesan.",
            ]
        ),
        DemoRecipe(
            id: "r-chili", title: "Slow-Cooker Turkey Chili",
            blurb: "In the slow cooker before school drop-off, ready at six.",
            art: "cooktop.fill:C2452D:6B1A10", prep: 15, cook: 360, serves: 10, difficulty: "easy",
            tags: ["dinner", "high-protein", "gluten-free"], creator: nil, status: "published", likes: 33, favorite: true, publishedDaysAgo: 150,
            ingredients: [
                "3|lb|ground turkey", "1|each|yellow onion, diced", "2|each|bell peppers, diced", "2|can|kidney beans, drained",
                "1|can|black beans, drained", "2|can|fire-roasted tomatoes", "3|tbsp|chili powder", "2|tsp|ground cumin", "2|cups|chicken broth",
            ],
            steps: [
                "Brown the turkey with the onion and peppers (or skip this on busy mornings).",
                "Add everything to the slow cooker and stir.",
                "Cook on low for 6 to 8 hours.",
                "Serve with cheddar, sour cream and cornbread.",
            ]
        ),
        DemoRecipe(
            id: "r-oats", title: "Cinnamon Apple Overnight Oats",
            blurb: "Six jars on Sunday night and breakfast is handled through Wednesday.",
            art: "mug.fill:D9A066:8A5A2B", prep: 10, cook: 0, serves: 6, difficulty: "easy",
            tags: ["breakfast", "vegetarian"], creator: nil, status: "published", likes: 17, favorite: false, publishedDaysAgo: 80,
            ingredients: [
                "3|cups|old-fashioned oats", "3|cups|milk", "1.5|cups|vanilla yogurt", "2|each|apples, diced",
                "2|tbsp|maple syrup", "2|tsp|cinnamon", "3|tbsp|chia seeds",
            ],
            steps: [
                "Stir the oats, milk, yogurt, chia, maple syrup and cinnamon together.",
                "Divide among six jars and top with the apples.",
                "Refrigerate overnight, or for up to four days.",
            ]
        ),
        DemoRecipe(
            id: "r-pinwheels", title: "Turkey Ranch Pinwheels",
            blurb: "Lunchbox-friendly and made the night before.",
            art: "takeoutbag.and.cup.and.straw.fill:5FB3A8:1D5F66", prep: 15, cook: 0, serves: 6, difficulty: "easy",
            tags: ["lunch"], creator: nil, status: "published", likes: 9, favorite: false, publishedDaysAgo: 45,
            ingredients: [
                "8|oz|cream cheese, softened", "1|packet|ranch seasoning", "6|each|large flour tortillas",
                "1|lb|sliced deli turkey", "2|cups|baby spinach", "1|cup|shredded cheddar",
            ],
            steps: [
                "Beat the cream cheese with the ranch seasoning.",
                "Spread it over the tortillas, then layer the turkey, spinach and cheddar.",
                "Roll tightly, wrap and chill for at least an hour.",
                "Slice into 1-inch rounds.",
            ]
        ),
        DemoRecipe(
            id: "r-frittata", title: "Veggie Sheet-Pan Frittata",
            blurb: "A dozen eggs and whatever's in the vegetable drawer, done in 20 minutes.",
            art: "frying.pan.fill:F2C14E:C27A12", prep: 10, cook: 20, serves: 8, difficulty: "easy",
            tags: ["breakfast", "vegetarian", "gluten-free"], creator: nil, status: "published", likes: 12, favorite: false, publishedDaysAgo: 30,
            ingredients: [
                "12|each|large eggs", "1|cup|milk", "1|each|red bell pepper, diced", "2|cups|baby spinach",
                "1|cup|cherry tomatoes, halved", "1|cup|shredded cheddar",
            ],
            steps: [
                "Heat the oven to 375°F and grease a sheet pan.",
                "Whisk the eggs and milk with salt and pepper.",
                "Scatter the vegetables and cheese over the pan and pour the eggs over.",
                "Bake 18 to 20 minutes until just set, then cut into squares.",
            ]
        ),
        DemoRecipe(
            id: "r-rolls", title: "Grandma Jo's Cinnamon Rolls",
            blurb: "Still testing the overnight version.",
            art: "birthday.cake.fill:E5B07A:9A5B2C", prep: 40, cook: 25, serves: 12, difficulty: "medium",
            tags: ["breakfast", "dessert"], creator: nil, status: "draft", likes: 0, favorite: false, publishedDaysAgo: 0,
            ingredients: [
                "4.5|cups|all-purpose flour", "1|packet|instant yeast", "1|cup|warm milk", "0.5|cup|butter, softened",
                "1|cup|brown sugar", "2|tbsp|cinnamon",
            ],
            steps: [
                "Make the dough and let it rise until doubled.",
                "Roll it out, spread with butter, sugar and cinnamon, and roll it up.",
                "Cut 12 rolls, let them rise 30 minutes, and bake at 350°F for 25 minutes.",
            ]
        ),
        DemoRecipe(
            id: "r-pancakes", title: "Blueberry Buttermilk Pancakes",
            blurb: "Tall Saturday-morning stacks, with a few berries in every bite.",
            art: "frying.pan.fill:8C7BE0:3E2E8F", prep: 10, cook: 20, serves: 6, difficulty: "easy",
            tags: ["breakfast", "vegetarian"], creator: "demo-okafor", status: "published", likes: 86, favorite: true, publishedDaysAgo: 210,
            ingredients: [
                "3|cups|all-purpose flour", "3|tbsp|sugar", "2|tsp|baking powder", "1|tsp|baking soda", "3|cups|buttermilk",
                "2|each|large eggs", "4|tbsp|butter, melted", "2|cups|blueberries",
            ],
            steps: [
                "Whisk the dry ingredients in one bowl and the buttermilk, eggs and butter in another.",
                "Stir them together until just combined; a few lumps are fine.",
                "Cook quarter-cup scoops on a buttered griddle, dotting with blueberries, until bubbles form, then flip.",
                "Keep them warm in a 200°F oven while you finish the batch.",
            ]
        ),
        DemoRecipe(
            id: "r-cookies", title: "Brown Butter Chocolate Chip Cookies",
            blurb: "Nutty, chewy, and worth browning the butter.",
            art: "birthday.cake.fill:A8714A:5A3520", prep: 20, cook: 12, serves: 24, difficulty: "easy",
            tags: ["dessert"], creator: "demo-okafor", status: "published", likes: 141, favorite: true, publishedDaysAgo: 160,
            ingredients: [
                "1|cup|butter", "1.25|cups|brown sugar", "0.5|cup|sugar", "2|each|large eggs", "2|tsp|vanilla",
                "2.75|cups|all-purpose flour", "1|tsp|baking soda", "2|cups|chocolate chips",
            ],
            steps: [
                "Brown the butter until it smells nutty and let it cool 10 minutes.",
                "Beat in the sugars, eggs and vanilla.",
                "Stir in the flour, baking soda, a teaspoon of salt and the chips.",
                "Scoop, chill 30 minutes, and bake at 350°F for 11 to 12 minutes.",
            ]
        ),
        DemoRecipe(
            id: "r-sliders", title: "BBQ Pulled Pork Sliders",
            blurb: "Feeds a crowd on game night.",
            art: "flame.fill:B5532F:5C2210", prep: 15, cook: 480, serves: 12, difficulty: "easy",
            tags: ["dinner", "pork", "american"], creator: "demo-okafor", status: "published", likes: 58, favorite: false, publishedDaysAgo: 90,
            ingredients: [
                "4|lb|pork shoulder", "1|cup|barbecue sauce", "0.5|cup|apple cider vinegar", "2|tbsp|brown sugar",
                "1|tbsp|smoked paprika", "24|each|slider buns", "4|cups|coleslaw mix",
            ],
            steps: [
                "Rub the pork with the sugar, paprika and salt.",
                "Slow-cook on low for 8 hours with the vinegar.",
                "Shred, discard the fat and stir in the sauce.",
                "Pile onto buns with slaw.",
            ]
        ),
        DemoRecipe(
            id: "r-fajitas", title: "Sheet-Pan Chicken Fajitas",
            blurb: "Everything on two pans, and everyone builds their own.",
            art: "flame.fill:F07A3A:A32E15", prep: 15, cook: 25, serves: 8, difficulty: "easy",
            tags: ["dinner", "chicken", "mexican"], creator: "demo-delgado", status: "published", likes: 97, favorite: true, publishedDaysAgo: 75,
            ingredients: [
                "3|lb|chicken breasts, sliced", "3|each|bell peppers, sliced", "1|each|red onion, sliced", "3|tbsp|olive oil",
                "2|tbsp|fajita seasoning", "16|each|flour tortillas", "2|each|limes",
            ],
            steps: [
                "Heat the oven to 425°F.",
                "Toss the chicken, peppers and onion with the oil and seasoning on two sheet pans.",
                "Roast 22 to 25 minutes, switching the pans halfway.",
                "Squeeze the limes over and serve with warm tortillas.",
            ]
        ),
        DemoRecipe(
            id: "r-soup", title: "Chicken Tortilla Soup",
            blurb: "Weeknight-fast, with all the toppings.",
            art: "cooktop.fill:E58A4E:933C1C", prep: 15, cook: 30, serves: 8, difficulty: "easy",
            tags: ["dinner", "chicken", "mexican"], creator: "demo-delgado", status: "published", likes: 44, favorite: false, publishedDaysAgo: 40,
            ingredients: [
                "2|lb|chicken thighs", "1|each|onion, diced", "1|can|fire-roasted tomatoes", "1|can|black beans",
                "1|cup|frozen corn", "8|cups|chicken broth", "2|tsp|ground cumin", "1|each|lime",
            ],
            steps: [
                "Soften the onion, then add the broth, tomatoes, cumin and chicken.",
                "Simmer 20 minutes, shred the chicken and return it to the pot.",
                "Add the beans and corn and simmer 10 minutes more.",
                "Serve with tortilla strips, avocado and lime.",
            ]
        ),
        DemoRecipe(
            id: "r-bowls", title: "Greek Chicken Rice Bowls",
            blurb: "Meal-prep lunches for the whole week.",
            art: "leaf.fill:4FA7C9:1F5F8A", prep: 20, cook: 20, serves: 6, difficulty: "easy",
            tags: ["lunch", "chicken", "greek", "mediterranean"], creator: "demo-delgado", status: "published", likes: 39, favorite: false, publishedDaysAgo: 22,
            ingredients: [
                "2|lb|chicken breasts", "0.25|cup|olive oil", "1|each|lemon", "2|tsp|dried oregano", "3|cups|cooked rice",
                "1|each|cucumber, diced", "1|cup|cherry tomatoes", "1|cup|tzatziki",
            ],
            steps: [
                "Marinate the chicken in the oil, lemon, oregano and garlic for 20 minutes.",
                "Grill or sear 6 minutes a side, then slice.",
                "Build bowls with rice, chicken, cucumber, tomatoes and tzatziki.",
            ]
        ),
        DemoRecipe(
            id: "r-enchiladas", title: "Green Chile Chicken Enchiladas",
            blurb: "My mom's recipe, doubled for two pans.",
            art: "oven.fill:7FA34B:3B5E1F", prep: 25, cook: 30, serves: 10, difficulty: "medium",
            tags: ["dinner", "chicken", "mexican"], creator: "demo-delgado", status: "published", likes: 23, favorite: false, publishedDaysAgo: 0.2,
            ingredients: [
                "4|cups|shredded chicken", "2|can|green enchilada sauce", "1|can|diced green chiles", "8|oz|cream cheese",
                "16|each|corn tortillas", "3|cups|shredded Monterey Jack",
            ],
            steps: [
                "Mix the chicken, chiles, cream cheese and a cup of the sauce.",
                "Roll the filling into the tortillas and lay them seam-side down in two pans.",
                "Cover with the rest of the sauce and the cheese.",
                "Bake at 375°F for 25 minutes.",
            ]
        ),
        DemoRecipe(
            id: "r-salmon", title: "Maple-Dijon Sheet-Pan Salmon",
            blurb: "Fifteen minutes in the oven, and the kids love the glaze.",
            art: "fish.fill:F08A6C:B8452F", prep: 10, cook: 15, serves: 6, difficulty: "easy",
            tags: ["dinner", "seafood", "gluten-free"], creator: "demo-lindqvist", status: "published", likes: 64, favorite: true, publishedDaysAgo: 55,
            ingredients: [
                "2.5|lb|salmon fillet", "3|tbsp|maple syrup", "2|tbsp|Dijon mustard", "1|tbsp|soy sauce",
                "1|lb|asparagus, trimmed", "1|each|lemon",
            ],
            steps: [
                "Heat the oven to 425°F.",
                "Whisk the maple syrup, mustard and soy sauce.",
                "Lay the salmon and asparagus on a sheet pan and brush with the glaze.",
                "Roast 12 to 15 minutes until the salmon flakes.",
            ]
        ),
        DemoRecipe(
            id: "r-meatballs", title: "Swedish Meatballs with Egg Noodles",
            blurb: "Mormor's recipe, with lingonberry jam on the side.",
            art: "fork.knife:C99363:7A4A26", prep: 25, cook: 30, serves: 8, difficulty: "medium",
            tags: ["dinner", "beef"], creator: "demo-lindqvist", status: "published", likes: 52, favorite: false, publishedDaysAgo: 130,
            ingredients: [
                "1|lb|ground beef", "1|lb|ground pork", "0.5|cup|breadcrumbs", "1|each|large egg", "0.5|tsp|ground allspice",
                "3|cups|beef broth", "1|cup|heavy cream", "1|lb|egg noodles",
            ],
            steps: [
                "Mix the meat, breadcrumbs, egg, allspice and salt, and roll into small meatballs.",
                "Brown them in batches.",
                "Make a gravy with butter, flour, the broth and cream, and simmer the meatballs in it for 10 minutes.",
                "Serve over buttered noodles with lingonberry jam.",
            ]
        ),
        DemoRecipe(
            id: "r-tortellini", title: "Creamy Tuscan Tortellini",
            blurb: "A twenty-minute dinner that tastes like a night out.",
            art: "fork.knife:E2B04A:9C6A16", prep: 10, cook: 20, serves: 6, difficulty: "easy",
            tags: ["dinner", "vegetarian", "italian"], creator: "demo-lindqvist", status: "published", likes: 71, favorite: false, publishedDaysAgo: 35,
            ingredients: [
                "2|lb|cheese tortellini", "2|tbsp|butter", "4|clove|garlic, minced", "0.5|cup|sun-dried tomatoes, chopped",
                "1.5|cups|heavy cream", "1|cup|grated Parmesan", "4|cups|baby spinach",
            ],
            steps: [
                "Cook the tortellini.",
                "Soften the garlic and sun-dried tomatoes in the butter, add the cream and simmer.",
                "Stir in the Parmesan and spinach until it wilts.",
                "Toss with the tortellini.",
            ]
        ),
        DemoRecipe(
            id: "r-curry", title: "Coconut Chickpea Curry",
            blurb: "Mild enough for the kids, with chili crisp on the table for the grown-ups.",
            art: "leaf.fill:E9B949:B06B13", prep: 10, cook: 25, serves: 6, difficulty: "easy",
            tags: ["dinner", "vegan", "indian", "gluten-free"], creator: "demo-raman", status: "published", likes: 88, favorite: false, publishedDaysAgo: 65,
            ingredients: [
                "2|can|chickpeas, drained", "1|can|coconut milk", "1|can|diced tomatoes", "1|each|onion, diced",
                "3|clove|garlic, minced", "1|tbsp|ginger, grated", "2|tbsp|curry powder", "4|cups|baby spinach",
            ],
            steps: [
                "Soften the onion, garlic and ginger in a little oil.",
                "Toast the curry powder for a minute.",
                "Add the chickpeas, tomatoes and coconut milk and simmer 15 minutes.",
                "Stir in the spinach and serve with rice and naan.",
            ]
        ),
        DemoRecipe(
            id: "r-stirfry", title: "Teriyaki Beef Stir-Fry",
            blurb: "Faster than takeout.",
            art: "frying.pan.fill:B0603A:5A2A14", prep: 15, cook: 15, serves: 6, difficulty: "easy",
            tags: ["dinner", "beef", "japanese"], creator: "demo-raman", status: "published", likes: 37, favorite: false, publishedDaysAgo: 18,
            ingredients: [
                "2|lb|flank steak, thinly sliced", "0.5|cup|teriyaki sauce", "1|head|broccoli, in florets",
                "2|each|carrots, sliced", "1|tbsp|cornstarch", "4|cups|cooked rice",
            ],
            steps: [
                "Toss the beef with the cornstarch.",
                "Sear it in batches over high heat.",
                "Stir-fry the vegetables, return the beef and add the sauce.",
                "Serve over rice.",
            ]
        ),
        DemoRecipe(
            id: "r-cobbler", title: "Skillet Peach Cobbler",
            blurb: "Summer peaches, or frozen ones in January.",
            art: "birthday.cake.fill:F5B184:D06A3A", prep: 15, cook: 40, serves: 10, difficulty: "easy",
            tags: ["dessert"], creator: "demo-raman", status: "published", likes: 45, favorite: false, publishedDaysAgo: 100,
            ingredients: [
                "6|cups|sliced peaches", "1|cup|sugar", "1|tsp|cinnamon", "1|cup|all-purpose flour", "2|tsp|baking powder",
                "1|cup|milk", "0.5|cup|butter",
            ],
            steps: [
                "Heat the oven to 350°F with the butter melting in a large skillet.",
                "Whisk the flour, half the sugar, the baking powder and milk, and pour it over the butter.",
                "Spoon the peaches, tossed with the rest of the sugar and the cinnamon, on top.",
                "Bake 40 minutes until golden.",
            ]
        ),
        DemoRecipe(
            id: "r-muffins", title: "Banana Oat Muffins",
            blurb: "Blender batter, and they freeze beautifully.",
            art: "cup.and.saucer.fill:D8A35B:8E5A22", prep: 10, cook: 20, serves: 12, difficulty: "easy",
            tags: ["breakfast", "vegetarian"], creator: "demo-harper", status: "published", likes: 29, favorite: false, publishedDaysAgo: 50,
            ingredients: [
                "3|each|ripe bananas", "2|cups|old-fashioned oats", "2|each|large eggs", "0.33|cup|maple syrup",
                "1|cup|milk", "1|tsp|baking powder", "1|tsp|cinnamon",
            ],
            steps: [
                "Blend everything until smooth.",
                "Divide among 12 muffin cups.",
                "Bake at 350°F for 20 minutes.",
            ]
        ),
    ]

    // MARK: Community

    static let cooks: [DemoCook] = [
        DemoCook(id: "demo-delgado", name: "Rosa Delgado", joinedDaysAgo: 610, followers: 2310, following: 140, recipeCount: 27, iFollow: true, followsMe: true, connectedDaysAgo: 190),
        DemoCook(id: "demo-okafor", name: "The Okafor Family", joinedDaysAgo: 540, followers: 1240, following: 86, recipeCount: 19, iFollow: true, followsMe: true, connectedDaysAgo: 230),
        DemoCook(id: "demo-raman", name: "Priya Raman", joinedDaysAgo: 300, followers: 1570, following: 210, recipeCount: 34, iFollow: true, followsMe: false, connectedDaysAgo: 120),
        DemoCook(id: "demo-lindqvist", name: "The Lindqvists", joinedDaysAgo: 420, followers: 880, following: 54, recipeCount: 12, iFollow: true, followsMe: false, connectedDaysAgo: 75),
        DemoCook(id: "demo-fontaine", name: "Marie Fontaine", joinedDaysAgo: 380, followers: 960, following: 33, recipeCount: 22, iFollow: false, followsMe: false, connectedDaysAgo: 40),
        DemoCook(id: "demo-harper", name: "Jess Harper", joinedDaysAgo: 210, followers: 132, following: 98, recipeCount: 6, iFollow: false, followsMe: true, connectedDaysAgo: 12),
        DemoCook(id: "demo-bennett", name: "Caleb & Joy Bennett", joinedDaysAgo: 150, followers: 210, following: 77, recipeCount: 9, iFollow: false, followsMe: true, connectedDaysAgo: 6),
        DemoCook(id: "demo-nakamura", name: "The Nakamuras", joinedDaysAgo: 95, followers: 64, following: 41, recipeCount: 4, iFollow: false, followsMe: true, connectedDaysAgo: 0.1),
    ]

    static func follows(mode: String, following: Set<String>) -> [String: Any] {
        let people: [DemoCook]
        switch mode {
        case "following": people = cooks.filter { following.contains($0.id) }
        case "followers": people = cooks.filter(\.followsMe)
        default: people = cooks
        }
        let profiles = people.map { $0.followJSON(isFollowing: following.contains($0.id)) }
        let pagination: [String: Any] = ["limit": 30, "offset": 0, "hasMore": false, "nextOffset": profiles.count, "totalCount": profiles.count]
        return ["mode": mode, "profiles": profiles, "pagination": pagination]
    }

    static func publicProfile(_ id: String) -> [String: Any]? {
        guard let cook = cooks.first(where: { $0.id == id }) else { return nil }
        let profile: [String: Any] = [
            "profileId": cook.id, "profileName": cook.name, "joinedAt": iso(minutesAgo: cook.joinedDaysAgo * 1440),
            "followerCount": cook.followers, "followingCount": cook.following,
        ]
        var shared: [[String: Any]] = []
        for recipe in recipes where recipe.creator == id && recipe.status == "published" {
            shared.append([
                "id": recipe.id, "title": recipe.title, "description": recipe.blurb, "imageUrl": recipe.imageURL,
                "publishedAt": iso(minutesAgo: recipe.publishedDaysAgo * 1440), "likeCount": recipe.likes,
            ])
        }
        return ["profile": profile, "recipes": shared]
    }

    // MARK: Notifications

    static let inbox: [DemoNotification] = [
        DemoNotification(id: "demo-note-1", type: "recipe_liked", actorID: "demo-harper", actorName: "Jess Harper", recipeID: "r-lasagna", minutesAgo: 25, unread: true),
        DemoNotification(id: "demo-note-2", type: "new_follower", actorID: "demo-nakamura", actorName: "The Nakamuras", recipeID: nil, minutesAgo: 140, unread: true),
        DemoNotification(id: "demo-note-3", type: "recipe_published", actorID: "demo-delgado", actorName: "Rosa Delgado", recipeID: "r-enchiladas", minutesAgo: 290, unread: true),
        DemoNotification(id: "demo-note-4", type: "recipe_saved", actorID: "demo-bennett", actorName: "Caleb & Joy Bennett", recipeID: "r-chicken", minutesAgo: 1500, unread: false),
        DemoNotification(id: "demo-note-5", type: "recipe_updated", actorID: "demo-lindqvist", actorName: "The Lindqvists", recipeID: "r-salmon", minutesAgo: 2900, unread: false),
        DemoNotification(id: "demo-note-6", type: "household_invitation_accepted", actorID: "demo-dan", actorName: "Dan Calloway", recipeID: nil, minutesAgo: 5800, unread: false),
        DemoNotification(id: "demo-note-7", type: "recipe_liked", actorID: "demo-raman", actorName: "Priya Raman", recipeID: "r-chili", minutesAgo: 8700, unread: false),
    ]

    static var unreadCount: Int { inbox.filter(\.unread).count }

    static func notifications(unreadOnly: Bool) -> [String: Any] {
        let records = inbox.filter { !unreadOnly || $0.unread }.map(\.json)
        let pagination: [String: Any] = ["limit": 30, "offset": 0, "hasMore": false, "nextOffset": records.count, "totalCount": records.count]
        return ["notifications": records, "pagination": pagination]
    }

    // MARK: Grocery

    /// "name|quantity|bulk|meals (;-separated)|checked" by aisle: this week's list, with the
    /// produce and most of the meat already in the cart.
    private static let aisles: [(name: String, icon: String, items: [String])] = [
        ("Produce", "🥬", [
            "Green beans|2 lb|0|Lemon Parmesan Green Beans|1",
            "Lemons|3|0|Lemon Parmesan Green Beans;Maple-Dijon Sheet-Pan Salmon|1",
            "Bell peppers|5|0|Sheet-Pan Chicken Fajitas;Veggie Sheet-Pan Frittata|1",
            "Yellow onions|3 lb bag|1||1",
            "Baby spinach|1 lb clamshell|1|Veggie Sheet-Pan Frittata;Coconut Chickpea Curry|1",
            "Honeycrisp apples|3 lb|0|Cinnamon Apple Overnight Oats|0",
            "Bananas|1 bunch|0||1",
            "Garlic|2 heads|0|Honey-Garlic Chicken Thighs|1",
            "Asparagus|1 lb|0|Maple-Dijon Sheet-Pan Salmon|0",
            "Limes|4|0|Sheet-Pan Chicken Fajitas|0",
        ]),
        ("Meat", "🥩", [
            "Bone-in chicken thighs|4 lb|0|Honey-Garlic Chicken Thighs|1",
            "Chicken breasts|3 lb|0|Sheet-Pan Chicken Fajitas|1",
            "Salmon fillet|2.5 lb|0|Maple-Dijon Sheet-Pan Salmon|0",
            "Ground turkey|3 lb|1|Slow-Cooker Turkey Chili|1",
        ]),
        ("Dairy", "🥛", [
            "Large eggs|2 dozen|1|Veggie Sheet-Pan Frittata;Blueberry Buttermilk Pancakes|0",
            "Whole milk|2 gal|0||0",
            "Buttermilk|1 qt|0|Blueberry Buttermilk Pancakes|0",
            "Shredded cheddar|2 lb|1|Veggie Sheet-Pan Frittata;Turkey Ranch Pinwheels|0",
            "Vanilla yogurt|32 oz|0|Cinnamon Apple Overnight Oats|0",
            "Parmesan|8 oz|0|Lemon Parmesan Green Beans|0",
        ]),
        ("Pantry", "🥫", [
            "Old-fashioned oats|42 oz|1|Cinnamon Apple Overnight Oats|0",
            "Honey|12 oz|0|Honey-Garlic Chicken Thighs|0",
            "Chickpeas|2 cans|0|Coconut Chickpea Curry|0",
            "Coconut milk|1 can|0|Coconut Chickpea Curry|0",
            "Fire-roasted tomatoes|2 cans|0|Slow-Cooker Turkey Chili|0",
            "Maple syrup|12 oz|0|Maple-Dijon Sheet-Pan Salmon|0",
        ]),
        ("Bakery", "🥖", [
            "Flour tortillas|16 ct|0|Sheet-Pan Chicken Fajitas;Turkey Ranch Pinwheels|0",
            "Sandwich bread|2 loaves|0||0",
        ]),
        ("Frozen", "❄️", [
            "Blueberries|3 lb|1|Blueberry Buttermilk Pancakes|0",
            "Sweet corn|1 lb|0||0",
        ]),
        ("Snacks", "🍿", [
            "Apple slices|6-pack|0||0",
            "Cheddar cheese sticks|24 ct|1||0",
            "Pretzel twists|1 bag|0||0",
        ]),
    ]

    static func grocerySnapshots() -> [[String: Any]] {
        var sections: [[String: Any]] = []
        var checks: [String: Bool] = [:]
        var allChecked: [String: Bool] = [:]
        var count = 0
        for (aisleIndex, aisle) in aisles.enumerated() {
            var items: [[String: Any]] = []
            for (itemIndex, line) in aisle.items.enumerated() {
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 5 else { continue }
                let id = "grocery-item-\(aisleIndex)-\(itemIndex)"
                let meals = fields[3].isEmpty ? [String]() : fields[3].components(separatedBy: ";")
                items.append(["id": id, "name": fields[0], "quantity": fields[1], "bulk": fields[2] == "1", "meals": meals])
                if fields[4] == "1" { checks[id] = true }
                allChecked[id] = true
                count += 1
            }
            sections.append(["name": aisle.name, "icon": aisle.icon, "items": items])
        }
        let ids = ScreenshotMode.grocerySnapshotIDs
        return [
            snapshot(id: ids[0], minutesAgo: 1 * 1440, cost: 286.40, sections: sections, checks: checks, count: count),
            snapshot(id: ids[1], minutesAgo: 8 * 1440, cost: 241.15, sections: sections, checks: allChecked, count: count),
            snapshot(id: ids[2], minutesAgo: 15 * 1440, cost: 263.80, sections: sections, checks: allChecked, count: count),
        ]
    }

    private static func snapshot(id: String, minutesAgo: Double, cost: Double, sections: [[String: Any]], checks: [String: Bool], count: Int) -> [String: Any] {
        [
            "id": id, "generatedAtIso": iso(minutesAgo: minutesAgo), "itemCount": count, "estimatedCost": cost,
            "source": "anthropic", "sections": sections, "checks": checks,
        ]
    }
}

#endif
