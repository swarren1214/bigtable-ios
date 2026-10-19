import Foundation
import Observation

// The recipe library's data: which recipes a screen is showing (RecipeStore, one per screen),
// and what every screen shares (RecipeLibrary: favorites, likes, publishing and custom tags,
// so a heart tapped in a recipe shows on the grid behind it).

/// Which recipes the Recipes tab is showing.
nonisolated enum RecipeCollection: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Everything published, plus the household's own.
    case all
    /// Recipes this person wrote.
    case mine
    /// Recipes they hearted.
    case favorites

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .mine: "Mine"
        case .favorites: "Favorites"
        }
    }
}

/// The filter chips under the search field, and the preset tags a recipe can have, in the Expo
/// app's order (RECIPE_QUICK_FILTERS).
enum RecipeQuickFilters {
    static let all = "All"

    static let values: [String] = [
        "All", "Breakfast", "Lunch", "Dinner", "Dessert", "Side", "Beef", "Chicken", "Seafood",
        "Pork", "Lamb", "Vegetarian", "Vegan", "Gluten-Free", "Dairy-Free", "Kosher", "Halal",
        "High-Protein", "Italian", "Mexican", "French", "American", "British", "Spanish", "Greek",
        "Mediterranean", "Middle-Eastern", "Caribbean", "African", "Indian", "Thai", "Japanese",
        "Chinese", "Vietnamese", "Korean", "Eastern-European",
    ]

    /// The preset tags (every filter but All).
    static var tags: [String] { values.filter { $0 != all } }

    static let normalizedTags: Set<String> = Set(values.filter { $0 != all }.map { $0.lowercased() })

    /// "gluten-free" → "Gluten-Free" for a preset; nil for anything else.
    static func presetLabel(for normalized: String) -> String? {
        tags.first { $0.lowercased() == normalized }
    }
}

/// Small helpers for showing and sorting recipes, shared by the Recipes screens.
enum RecipeFormat {
    /// "45 min · Serves 8 · Easy · 3 likes", as the Expo app's recipe cards read.
    static func facts(prepMinutes: Int?, cookMinutes: Int?, baseServings: Double, sourceName: String, difficulty: String?, likeCount: Int?) -> String {
        var parts: [String] = []
        let total = (prepMinutes ?? 0) + (cookMinutes ?? 0)
        if total > 0 { parts.append(durationText(minutes: total)) }
        if baseServings > 0, sourceName != "themealdb" { parts.append("Serves \(servings(baseServings))") }
        if let difficulty, !difficulty.recipeTrimmed.isEmpty { parts.append(difficulty.capitalized) }
        if let likeCount, likeCount > 0 { parts.append(likeCount == 1 ? "1 like" : "\(likeCount) likes") }
        return parts.joined(separator: " · ")
    }

    static func facts(_ recipe: RecipeSummary) -> String {
        facts(prepMinutes: recipe.prepMinutes, cookMinutes: recipe.cookMinutes, baseServings: recipe.baseServings, sourceName: recipe.sourceName, difficulty: recipe.difficulty, likeCount: recipe.likeCount)
    }

    /// 8.0 → "8", 2.5 → "2.5".
    static func servings(_ value: Double) -> String {
        Ingredients.formatAmount(value)
    }

    /// Titles in reading order, ignoring accents, case and punctuation, numbers in number order.
    static func sortedByTitle(_ recipes: [RecipeSummary]) -> [RecipeSummary] {
        func key(_ title: String) -> String {
            title.folding(options: [.diacriticInsensitive], locale: nil).recipeTrimmed
        }
        return recipes.sorted { key($0.title).localizedStandardCompare(key($1.title)) == .orderedAscending }
    }

    /// The Expo app's client-side search for favorites: title, description or a tag.
    static func matches(_ recipe: RecipeSummary, query: String) -> Bool {
        let needle = query.recipeTrimmed.lowercased()
        guard !needle.isEmpty else { return true }
        return recipe.title.lowercased().contains(needle)
            || (recipe.description?.lowercased().contains(needle) ?? false)
            || recipe.tags.contains { $0.lowercased().contains(needle) }
    }

    static func matches(_ recipe: RecipeSummary, quickFilter: String) -> Bool {
        let filter = quickFilter.recipeTrimmed.lowercased()
        guard !filter.isEmpty, filter != "all" else { return true }
        return matches(recipe, query: filter)
    }

    /// "1. Preheat the oven" → "Preheat the oven". Steps are saved numbered so both apps agree.
    nonisolated static func stripStepNumber(_ step: String) -> String {
        step.replacingOccurrences(of: #"^\s*(?:step\s*)?\d+\s*[.):\-]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .recipeTrimmed
    }

    /// The signed-in person wrote it (their profile created it, or it's a household recipe
    /// with no creator recorded).
    static func isOwned(createdByProfileId: String?, sourceName: String) -> Bool {
        if let creator = createdByProfileId?.recipeTrimmed, !creator.isEmpty {
            return creator == AppModel.shared.userID
        }
        return sourceName.recipeTrimmed.lowercased() == "user"
    }

    static func isOwned(_ recipe: RecipeSummary) -> Bool {
        isOwned(createdByProfileId: recipe.createdByProfileId, sourceName: recipe.sourceName)
    }

    /// A recipe's card, from its full detail.
    static func summary(from detail: RecipeDetail) -> RecipeSummary {
        RecipeSummary(
            id: detail.id,
            title: detail.title,
            description: detail.description,
            imageUrl: detail.imageUrl,
            prepMinutes: detail.prepMinutes,
            cookMinutes: detail.cookMinutes,
            baseServings: detail.baseServings,
            difficulty: detail.difficulty,
            tags: detail.tags,
            sourceName: detail.sourceName,
            sourceUrl: detail.sourceUrl,
            attributionRequired: detail.attributionRequired,
            attributionText: detail.attributionText,
            isFavorite: detail.isFavorite,
            isLiked: detail.isLiked,
            likeCount: detail.likeCount,
            createdByProfileId: detail.createdByProfileId,
            creatorName: detail.creatorName,
            creatorAvatarUrl: detail.creatorAvatarUrl,
            status: detail.status,
            currentVersionId: detail.currentVersionId,
            pinnedVersionId: detail.pinnedVersionId,
            hasUpdateAvailable: detail.hasUpdateAvailable,
            publishedAt: detail.publishedAt
        )
    }
}

extension String {
    /// Without leading and trailing spaces and newlines.
    nonisolated var recipeTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// What every recipe screen shares: favorites, likes and publishing (applied to every open
/// list at once, and rolled back if the server says no), the person's own tags, and a
/// revision that bumps when a recipe is created, edited, restored or deleted so open screens
/// refresh.
@MainActor
@Observable
final class RecipeLibrary {
    static let shared = RecipeLibrary()

    /// The person's custom tags, sorted by name.
    private(set) var customTags: [CustomTag] = []
    private(set) var customTagsLoaded = false
    /// Bumps when recipes were added, changed or removed.
    private(set) var revision = 0
    /// Tags renamed in Manage Tags this session: old normalized value → new.
    private(set) var renamedTags: [String: String] = [:]

    @ObservationIgnored private var stores: [RecipeStoreBox] = []
    private let api = BigTableAPI.shared

    private struct RecipeStoreBox {
        weak var store: RecipeStore?
    }

    private var liveStores: [RecipeStore] { stores.compactMap(\.store) }

    func register(_ store: RecipeStore) {
        stores.removeAll { $0.store == nil }
        stores.append(RecipeStoreBox(store: store))
    }

    /// Changes one recipe in every open list.
    func update(_ id: String, _ change: (inout RecipeSummary) -> Void) {
        for store in liveStores { store.mutate(id, change) }
    }

    /// Takes a recipe out of every open list (it was deleted).
    func remove(_ id: String) {
        for store in liveStores { store.removeLocally(id) }
    }

    /// Recipes were created, edited, restored or deleted: open lists reload.
    func changed() {
        revision += 1
        for store in liveStores where store.hasLoaded {
            Task { await store.reload() }
        }
    }

    // MARK: Favorites and likes

    /// Hearts or un-hearts a recipe everywhere at once, and puts it back if the server fails.
    func setFavorite(id: String, saved: Bool) async throws {
        update(id) { $0.isFavorite = saved }
        do {
            try await KitchenStore.shared.setFavorite(id, saved: saved)
            for store in liveStores where store.collection == .favorites && store.hasLoaded {
                if saved {
                    Task { await store.reload() }
                } else {
                    store.removeLocally(id)
                }
            }
        } catch {
            update(id) { $0.isFavorite = !saved }
            throw error
        }
    }

    /// Likes or unlikes someone's published recipe, adjusting the count, with rollback.
    func setLike(id: String, liked: Bool, previousCount: Int?) async throws {
        let previousLiked = !liked
        let nextCount = max(0, (previousCount ?? 0) + (liked ? 1 : -1))
        update(id) {
            $0.isLiked = liked
            $0.likeCount = nextCount
        }
        do {
            try await api.setLike(id, liked: liked)
        } catch {
            update(id) {
                $0.isLiked = previousLiked
                $0.likeCount = previousCount
            }
            throw error
        }
    }

    // MARK: Custom tags

    func loadCustomTags(force: Bool = false) async {
        guard force || !customTagsLoaded else { return }
        if let tags = try? await KitchenStore.shared.customTags() {
            customTags = sorted(tags)
            customTagsLoaded = true
        }
    }

    func createTag(_ label: String) async throws -> CustomTag {
        let tag = try await KitchenStore.shared.createTag(label)
        upsert(tag)
        return tag
    }

    func renameTag(_ tag: CustomTag, to label: String) async throws -> CustomTag {
        let renamed = try await KitchenStore.shared.renameTag(tag.id, to: label)
        customTags.removeAll { $0.id == tag.id }
        upsert(renamed)
        if renamed.normalized != tag.normalized {
            renamedTags[tag.normalized] = renamed.normalized
            for (old, new) in renamedTags where new == tag.normalized {
                renamedTags[old] = renamed.normalized
            }
        }
        return renamed
    }

    func deleteTag(_ tag: CustomTag) async throws {
        try await KitchenStore.shared.deleteTag(tag.id)
        customTags.removeAll { $0.id == tag.id }
    }

    /// Plain words for a tag that couldn't be saved; 409 is a name already in use.
    func tagErrorMessage(_ error: Error, label: String) -> String {
        if let api = error as? APIError, api.status == 409 {
            return "You already have a tag called “\(label.uppercased())”. Pick a different name."
        }
        return error.localizedDescription
    }

    private func upsert(_ tag: CustomTag) {
        customTags.removeAll { $0.id == tag.id || $0.normalized == tag.normalized }
        customTags.append(tag)
        customTags = sorted(customTags)
    }

    private func sorted(_ tags: [CustomTag]) -> [CustomTag] {
        tags.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

/// One screen's list of recipes: a collection (All, Mine, Favorites), a search (debounced)
/// and a quick filter, loaded the way the Expo app loaded them. All recipes with no filter
/// load 20 at a time as you scroll; Mine and a filtered All load every page at once; Favorites
/// come in one call and are searched and filtered on the phone.
@MainActor
@Observable
final class RecipeStore {
    var collection: RecipeCollection
    var query = ""
    var quickFilter = RecipeQuickFilters.all

    private(set) var recipes: [RecipeSummary] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var hasLoaded = false
    private(set) var loadError: String?

    let pageSize: Int

    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private let api = BigTableAPI.shared

    init(collection: RecipeCollection = .all, pageSize: Int = 20) {
        self.collection = collection
        self.pageSize = pageSize
        RecipeLibrary.shared.register(self)
    }

    /// Only the unfiltered All list loads page by page; the others arrive whole.
    var canPaginate: Bool { collection == .all && quickFilter == RecipeQuickFilters.all }

    /// The search field changed: wait for typing to pause, then reload.
    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await self.reload()
        }
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    /// Loads the first page (or everything) for the current collection, search and filter.
    func reload() async {
        generation += 1
        let token = generation
        let query = self.query
        let filter = self.quickFilter
        let collection = self.collection
        isLoading = true
        loadError = nil
        do {
            let result: (recipes: [RecipeSummary], offset: Int, hasMore: Bool)
            switch collection {
            case .favorites:
                let response = try await KitchenStore.shared.favoriteRecipes()
                let matching = response.recipes.filter {
                    RecipeFormat.matches($0, query: query) && RecipeFormat.matches($0, quickFilter: filter)
                }
                result = (RecipeFormat.sortedByTitle(matching), matching.count, false)
            case .mine:
                let all = try await fetchEveryPage(query: query, filter: filter, collection: "my")
                result = (RecipeFormat.sortedByTitle(all), all.count, false)
            case .all where filter != RecipeQuickFilters.all:
                let all = try await fetchEveryPage(query: query, filter: filter, collection: nil)
                result = (RecipeFormat.sortedByTitle(all), all.count, false)
            case .all:
                let page = try await KitchenStore.shared.recipes(query: query, quickFilter: filter, collection: nil, limit: pageSize, offset: 0)
                // The first page also carries the family's own recipes; paging follows the server's.
                result = (RecipeFormat.sortedByTitle(page.recipes), page.pagination?.nextOffset ?? page.recipes.count, page.pagination?.hasMore ?? false)
            }
            guard token == generation else { return }
            recipes = result.recipes
            offset = result.offset
            hasMore = result.hasMore
            hasLoaded = true
        } catch is CancellationError {
            // A newer load replaced this one.
        } catch {
            guard token == generation else { return }
            loadError = error.localizedDescription
        }
        if token == generation { isLoading = false }
    }

    /// Call as each card appears; the last one loads the next page.
    func loadMoreIfNeeded(after recipe: RecipeSummary) {
        guard recipe.id == recipes.last?.id else { return }
        Task { await loadMore() }
    }

    func loadMore() async {
        guard canPaginate, hasMore, !isLoading, !isLoadingMore else { return }
        let token = generation
        isLoadingMore = true
        do {
            let page = try await KitchenStore.shared.recipes(query: query, quickFilter: quickFilter, collection: nil, limit: pageSize, offset: offset)
            if token == generation {
                let known = Set(recipes.map(\.id))
                let fresh = page.recipes.filter { !known.contains($0.id) }
                recipes = RecipeFormat.sortedByTitle(recipes + fresh)
                offset = page.pagination?.nextOffset ?? offset + page.recipes.count
                // A page can be empty here when it held only the family's own recipes (shown
                // already); the server's own paging says whether there's more.
                hasMore = page.pagination?.hasMore ?? false
            }
        } catch {
            if token == generation { loadError = error.localizedDescription }
        }
        isLoadingMore = false
    }

    /// Mine, and All with a filter: every page, as the Expo app did (capped well past any
    /// real library so a server bug can't loop forever).
    private func fetchEveryPage(query: String, filter: String, collection: String?) async throws -> [RecipeSummary] {
        var all: [RecipeSummary] = []
        var offset = 0
        for _ in 0..<50 {
            let page = try await KitchenStore.shared.recipes(query: query, quickFilter: filter, collection: collection, limit: pageSize, offset: offset)
            let known = Set(all.map(\.id))
            all.append(contentsOf: page.recipes.filter { !known.contains($0.id) })
            offset = page.pagination?.nextOffset ?? offset + page.recipes.count
            if page.pagination?.hasMore != true { break }
        }
        return all
    }

    // MARK: Local changes (from RecipeLibrary)

    func mutate(_ id: String, _ change: (inout RecipeSummary) -> Void) {
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return }
        change(&recipes[index])
    }

    func removeLocally(_ id: String) {
        recipes.removeAll { $0.id == id }
    }
}
