import Foundation

/// The calls screens make for the family's own recipes, plan, grocery lists and tags. They
/// match the API calls they replace (same names and shapes), but read and write the kitchen in
/// iCloud. Published and community recipes, favorites of them, likes and AI still go to the
/// server through `BigTableAPI`.
extension KitchenStore {
    private var api: BigTableAPI { .shared }

    // MARK: - Recipes

    /// `collection`: nil for everything (the family's own plus everything published), "my" for
    /// the family's own, "removed" for deleted. The first page of "everything" carries all of
    /// the family's matching recipes; later pages are the server's.
    func recipes(query: String? = nil, quickFilter: String? = nil, collection: String? = nil, limit: Int = 20, offset: Int = 0) async throws -> RecipeListResponse {
        let removed = collection == "removed"
        let own = ownSummaries(query: query, quickFilter: quickFilter, removed: removed)
        if collection == "my" || removed {
            let page = Array(own.dropFirst(offset).prefix(limit))
            return RecipeListResponse(recipes: page, pagination: Pagination(limit: limit, offset: offset, hasMore: offset + page.count < own.count, nextOffset: offset + page.count, totalCount: own.count))
        }
        let server = try await api.recipes(query: query, quickFilter: quickFilter, collection: nil, limit: limit, offset: offset)
        let mine = Set(state.recipes.keys)
        let published = server.recipes.filter { !mine.contains($0.id) }
        return RecipeListResponse(
            recipes: offset == 0 ? own + published : published,
            pagination: Pagination(limit: limit, offset: offset, hasMore: server.pagination?.hasMore, nextOffset: offset + server.recipes.count, totalCount: nil)
        )
    }

    /// The family's recipes as cards, matching a search and a filter chip the way the server did.
    func ownSummaries(query: String? = nil, quickFilter: String? = nil, removed: Bool = false) -> [RecipeSummary] {
        let needle = query?.recipeTrimmed.lowercased() ?? ""
        let tag = quickFilter?.recipeTrimmed.lowercased() ?? ""
        let matching = state.recipes.values.filter { recipe in
            (recipe.deletedAt != nil) == removed
                && (needle.isEmpty || recipe.detail.title.lowercased().contains(needle))
                && (tag.isEmpty || tag == "all" || recipe.detail.tags.contains { $0.lowercased() == tag })
        }
        return RecipeFormat.sortedByTitle(matching.map { RecipeFormat.summary(from: display($0.detail)) })
    }

    /// Whether a recipe is the family's own (in the kitchen).
    func isOwn(_ id: String) -> Bool { state.recipes[id] != nil }

    func recipe(_ id: String, versionId: String? = nil) async throws -> RecipeDetail {
        if let own = state.recipes[id] { return display(own.detail) }
        return try await api.recipe(id, versionId: versionId)
    }

    /// The recipe as screens show it: its photo as a file URL.
    func display(_ detail: RecipeDetail) -> RecipeDetail {
        var shown = detail
        shown.imageUrl = KitchenPhotos.display(detail.imageUrl)
        return shown
    }

    /// Keeps a photo the cook picked or took, for a recipe being written. Returns what the
    /// editor shows (a file URL); saving stores it in the kitchen.
    func savePhoto(_ data: Data, mimeType: String = "image/jpeg") -> String? {
        let ext = mimeType.contains("png") ? "png" : mimeType.contains("webp") ? "webp" : "jpg"
        return KitchenPhotos.display(KitchenPhotos.save(data, ext: ext))
    }

    func createRecipe(_ payload: RecipePayload) async throws -> String {
        let id = UUID().uuidString.lowercased()
        var detail = RecipeDetail(
            id: id, title: payload.title, description: nil, imageUrl: nil, prepMinutes: nil, cookMinutes: nil,
            baseServings: 8, difficulty: nil, tags: [], sourceName: "user", sourceUrl: nil,
            attributionRequired: false, attributionText: nil, isFavorite: true, isLiked: nil, likeCount: nil,
            createdByProfileId: AppModel.shared.userID, creatorName: nil, creatorAvatarUrl: nil, status: .draft,
            currentVersionId: nil, pinnedVersionId: nil, hasUpdateAvailable: nil, publishedAt: nil,
            instructions: [], ingredients: [], versionCount: nil
        )
        apply(payload, to: &detail)
        put(recipe: KitchenRecipe(detail: detail, deletedAt: nil, updatedAt: .now))
        return id
    }

    func updateRecipe(_ id: String, _ payload: RecipePayload) async throws {
        guard var recipe = state.recipes[id] else { throw APIError(kind: .rejected, status: 404, message: "That recipe isn't in your kitchen.") }
        apply(payload, to: &recipe.detail)
        recipe.updatedAt = .now
        put(recipe: recipe)
        // A published recipe's copy on the server follows.
        if recipe.detail.status == .published {
            _ = try await publishRecipe(id)
        }
    }

    private func apply(_ payload: RecipePayload, to detail: inout RecipeDetail) {
        detail.title = payload.title.recipeTrimmed
        detail.imageUrl = KitchenPhotos.stored(payload.imageUrl)
        detail.description = payload.description
        detail.prepMinutes = payload.prepMinutes
        detail.cookMinutes = payload.cookMinutes
        if let servings = payload.baseServings, servings > 0 { detail.baseServings = servings }
        detail.difficulty = payload.difficulty
        if let tags = payload.tags { detail.tags = tags }
        if let ingredients = payload.ingredients {
            detail.ingredients = ingredients.map { RecipeIngredient(id: UUID().uuidString.lowercased(), amount: $0.amount, measurementType: $0.measurementType, name: $0.name) }
        }
        if let steps = payload.instructions {
            // Steps are kept numbered ("1. …"), as the server kept them.
            detail.instructions = steps.enumerated().map { index, step in
                "\(index + 1). \(RecipeFormat.stripStepNumber(step))"
            }
        }
    }

    func deleteRecipe(_ id: String) async throws {
        guard var recipe = state.recipes[id] else { return }
        let wasPublished = recipe.detail.status == .published
        recipe.deletedAt = .now
        recipe.updatedAt = .now
        if wasPublished { recipe.detail.status = .unpublished }
        put(recipe: recipe)
        if wasPublished { try? await api.unpublishPublication(id) }
    }

    func deletedRecipes() async throws -> RecipeListResponse {
        RecipeListResponse(recipes: ownSummaries(removed: true), pagination: nil)
    }

    func restoreRecipe(_ id: String) async throws {
        guard var recipe = state.recipes[id] else { return }
        recipe.deletedAt = nil
        recipe.updatedAt = .now
        put(recipe: recipe)
    }

    /// Copies the recipe to the server under the same id, where the community can see it. A
    /// photo kept in the kitchen is uploaded first (published recipes need a public photo).
    func publishRecipe(_ id: String) async throws -> PublishRecipeResponse {
        guard let start = state.recipes[id] else { return try await api.publishRecipe(id) }
        let imageURL = try await publicPhotoURL(for: start.detail)
        let detail = start.detail
        let payload = RecipePayload(
            title: detail.title, imageUrl: imageURL, description: detail.description,
            prepMinutes: detail.prepMinutes, cookMinutes: detail.cookMinutes, baseServings: detail.baseServings,
            difficulty: detail.difficulty, tags: detail.tags,
            ingredients: detail.ingredients.map(\.input), instructions: detail.instructions
        )
        await shareDisplayNameIfNeeded()
        let response = try await api.putPublication(id, payload)
        // Changes made while this was uploading stay; only the publishing details are set.
        guard var recipe = state.recipes[id] else { return response }
        recipe.detail.status = .published
        recipe.detail.publishedAt = recipe.detail.publishedAt ?? ISO8601DateFormatter().string(from: .now)
        recipe.detail.currentVersionId = response.versionId ?? recipe.detail.currentVersionId
        recipe.updatedAt = .now
        put(recipe: recipe)
        return response
    }

    /// The photo's public URL for the published copy: uploaded once per photo (remembered on
    /// this device); an https photo is used as it is.
    private func publicPhotoURL(for detail: RecipeDetail) async throws -> String {
        let stored = detail.imageUrl ?? ""
        if stored.hasPrefix("http") { return stored }
        guard let name = KitchenPhotos.name(in: stored) else {
            throw APIError(kind: .rejected, status: 400, message: "Add a photo before publishing.")
        }
        var uploaded = UserDefaults.standard.dictionary(forKey: "kitchen.uploadedPhotos") as? [String: String] ?? [:]
        if let url = uploaded[name] { return url }
        guard let data = KitchenPhotos.data(for: stored) else {
            throw APIError(kind: .rejected, status: 409, message: "The recipe's photo is still coming down from iCloud. Try again in a moment.")
        }
        let mime = name.hasSuffix(".png") ? "image/png" : name.hasSuffix(".webp") ? "image/webp" : "image/jpeg"
        let url = try await StorageClient.shared.uploadRecipePhoto(data, mimeType: mime)
        uploaded[name] = url
        UserDefaults.standard.set(uploaded, forKey: "kitchen.uploadedPhotos")
        return url
    }

    /// Published recipes show who made them. That name (just the first name) is the only thing
    /// about the family the server learns, and only once someone publishes.
    private func shareDisplayNameIfNeeded() async {
        let name = HearthHouseholdStore.shared.me?.firstName ?? AppModel.shared.me?.myMember?.name.split(separator: " ").first.map(String.init)
        guard let name, !name.isEmpty, UserDefaults.standard.string(forKey: "kitchen.displayName") != name else { return }
        if (try? await api.setDisplayName(name)) != nil {
            UserDefaults.standard.set(name, forKey: "kitchen.displayName")
        }
    }

    func unpublishRecipe(_ id: String) async throws -> PublishRecipeResponse {
        guard var recipe = state.recipes[id] else { return try await api.unpublishRecipe(id) }
        let response = try await api.unpublishPublication(id)
        recipe.detail.status = .unpublished
        recipe.updatedAt = .now
        put(recipe: recipe)
        return response
    }

    // MARK: - Favorites (the family's own are marked here; published ones on the server)

    func favoriteRecipes() async throws -> RecipeListResponse {
        let server = try await api.favoriteRecipes()
        let own = ownSummaries().filter(\.isFavorite)
        let ownIDs = Set(own.map(\.id))
        return RecipeListResponse(recipes: own + server.recipes.filter { !ownIDs.contains($0.id) }, pagination: server.pagination)
    }

    func setFavorite(_ id: String, saved: Bool) async throws {
        guard var recipe = state.recipes[id] else {
            try await api.setFavorite(id, saved: saved)
            return
        }
        guard recipe.detail.isFavorite != saved else { return }
        recipe.detail.isFavorite = saved
        recipe.updatedAt = .now
        put(recipe: recipe)
    }

    // MARK: - Tags

    func customTags() async throws -> [CustomTag] {
        state.tags.values.map(\.tag).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    func createTag(_ label: String) async throws -> CustomTag {
        let cleaned = label.recipeTrimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { throw APIError(kind: .rejected, status: 400, message: "Give the tag a name.") }
        let normalized = cleaned.lowercased()
        if let existing = state.tags.values.first(where: { $0.tag.normalized == normalized }) { return existing.tag }
        let tag = CustomTag(id: UUID().uuidString.lowercased(), label: cleaned, normalized: normalized)
        put(tag: KitchenTag(tag: tag, updatedAt: .now))
        return tag
    }

    func renameTag(_ id: String, to label: String) async throws -> CustomTag {
        let cleaned = label.recipeTrimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty, let existing = state.tags[id] else { throw APIError(kind: .rejected, status: 400, message: "Give the tag a name.") }
        var tag = existing.tag
        let old = tag.label
        tag.label = cleaned
        tag.normalized = cleaned.lowercased()
        put(tag: KitchenTag(tag: tag, updatedAt: .now))
        // Recipes carry tag labels; rename them there too.
        for var recipe in state.recipes.values where recipe.detail.tags.contains(old) {
            recipe.detail.tags = recipe.detail.tags.map { $0 == old ? cleaned : $0 }
            recipe.updatedAt = .now
            put(recipe: recipe)
        }
        return tag
    }

    func deleteTag(_ id: String) async throws {
        removeTag(id)
    }

    // MARK: - Plan

    func currentPlan(weekStart: String?) async throws -> PlannerResponse {
        let week = weekStart ?? ISODay.weekStart(containing: .now)
        var plan = PlannerResponse(planId: "kitchen-" + week, weekStart: week, days: [:])
        for slot in state.slots.values where slot.weekStart == week {
            plan.set(displaySlot(slot.value), day: slot.day, slot: slot.slot)
        }
        return plan
    }

    /// Recipe photos in a slot as screens show them (the family's own may have changed).
    private func displaySlot(_ slot: PlannerSlot) -> PlannerSlot {
        var shown = slot
        shown.recipeItems = slot.recipeItems.map { item in
            var item = item
            if let id = item.recipeId, let own = state.recipes[id] {
                item.imageUrl = KitchenPhotos.display(own.detail.imageUrl)
                item.title = own.detail.title
            } else {
                item.imageUrl = KitchenPhotos.display(item.imageUrl)
            }
            return item
        }
        return shown
    }

    func updateSlot(_ update: PlanSlotUpdate) async throws -> PlannerSlotUpdateResponse {
        let week = update.weekStart ?? ISODay.weekStart(containing: .now)
        let key = KitchenSlot.key(weekStart: week, day: update.day, slot: update.slot)
        var value = state.slots[key]?.value ?? PlannerSlot()
        let wasCompleted = value.completed
        if let customMeal = update.customMeal { value.customMeal = customMeal }
        if let dineOut = update.dineOut { value.dineOut = dineOut }
        if let items = update.recipeItems {
            value.recipeItems = items.map { item in
                var item = item
                item.imageUrl = KitchenPhotos.stored(item.imageUrl)
                return item
            }
        }
        if let snacks = update.snackItems { value.snackItems = snacks }
        if let excluded = update.excludedMembers { value.excludedMembers = excluded }
        if let completed = update.completed { value.completed = completed }
        value.id = value.id ?? key
        put(slot: KitchenSlot(weekStart: week, day: update.day, slot: update.slot, value: value, updatedAt: .now))
        // Cooking it takes its ingredients off the pantry; unmarking puts them back.
        if value.completed != wasCompleted { mealCooked(value, key: key, completed: value.completed) }
        return PlannerSlotUpdateResponse(day: update.day, slot: update.slot, weekStart: week, planId: "kitchen-" + week, slotData: displaySlot(value))
    }

    /// Every planned slot between two days ("YYYY-MM-DD"), in order: for grocery lists and the
    /// AI planner.
    func plannedSlots(from start: String, to end: String) -> [(date: String, day: DayOfWeek, slot: MealSlotType, value: PlannerSlot)] {
        let offsets: [DayOfWeek: Int] = [.sunday: 0, .monday: 1, .tuesday: 2, .wednesday: 3, .thursday: 4, .friday: 5, .saturday: 6]
        return state.slots.values.compactMap { slot in
            let date = ISODay.adding(days: offsets[slot.day] ?? 0, to: slot.weekStart)
            guard date >= start, date <= end, !slot.value.isEmpty else { return nil }
            return (date, slot.day, slot.slot, slot.value)
        }
        .sorted { ($0.date, MealSlotType.allCases.firstIndex(of: $0.slot) ?? 0) < ($1.date, MealSlotType.allCases.firstIndex(of: $1.slot) ?? 0) }
    }

    // MARK: - Grocery lists

    func grocerySnapshots() async throws -> GrocerySnapshotsResponse {
        let lists = state.groceries.values.map(\.snapshot).sorted { $0.generatedAtIso > $1.generatedAtIso }
        for list in lists { loadedChecks[list.id] = list.checks }
        return GrocerySnapshotsResponse(snapshots: lists, activeSnapshotId: state.settings.activeGroceryID ?? lists.first?.id)
    }

    func saveGrocerySnapshot(_ payload: SaveGrocerySnapshotPayload) async throws -> GrocerySnapshot {
        var snapshot: GrocerySnapshot
        if let id = payload.id, let existing = state.groceries[id]?.snapshot {
            snapshot = existing
        } else {
            snapshot = GrocerySnapshot(
                id: payload.id ?? UUID().uuidString.lowercased(),
                generatedAtIso: ISO8601DateFormatter().string(from: .now),
                itemCount: 0, estimatedCost: 0, source: payload.source ?? .manual, sections: [], checks: [:]
            )
        }
        if let sections = payload.sections { snapshot.sections = sections }
        // Only the ticks changed on this phone since it loaded the list; someone else's ticks
        // in the meantime stay.
        if let base = loadedChecks[snapshot.id] {
            for key in Set(payload.checks.keys).union(base.keys) where payload.checks[key] != base[key] {
                snapshot.checks[key] = payload.checks[key]
            }
        } else {
            snapshot.checks = payload.checks
        }
        // What this phone's screen now holds; ticks from elsewhere stay differences to keep.
        loadedChecks[snapshot.id] = payload.checks
        if let cost = payload.estimatedCost { snapshot.estimatedCost = cost }
        if let source = payload.source { snapshot.source = source }
        snapshot.itemCount = snapshot.sections.reduce(0) { $0 + $1.items.count }
        put(grocery: KitchenGrocery(snapshot: snapshot, updatedAt: .now))
        if payload.makeActive == true || state.settings.activeGroceryID == nil { setActiveGrocery(snapshot.id) }
        return snapshot
    }
}
