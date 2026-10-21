import Foundation
import Observation

/// The household's weekly plans (Sunday-start weeks), shared by the Plan tab and the AI
/// planner. Weeks are kept once loaded so swiping back is instant; every edit shows right away
/// and is put back if it doesn't save.
@MainActor
@Observable
final class PlanStore {
    static let shared = PlanStore()

    /// Loaded weeks by their Sunday ("YYYY-MM-DD").
    private(set) var weeks: [String: PlannerResponse] = [:]
    private(set) var loadingWeeks: Set<String> = []
    /// Why a week couldn't be loaded (only when there's nothing to show for it).
    private(set) var loadErrors: [String: String] = [:]
    /// Slots with a save in flight (`PlanSlotRef.id`).
    private(set) var savingSlots: Set<String> = []
    /// Something the person tried didn't save; shown as an alert.
    var actionError: String?

    @ObservationIgnored private var loadedAt: [String: Date] = [:]
    @ObservationIgnored private let api = BigTableAPI.shared

    // MARK: Reading

    func planner(_ weekStart: String) -> PlannerResponse? { weeks[weekStart] }

    func slot(_ ref: PlanSlotRef) -> PlannerSlot {
        weeks[ref.weekStart]?.slot(ref.day, ref.slot) ?? PlannerSlot()
    }

    func isLoading(_ weekStart: String) -> Bool { loadingWeeks.contains(weekStart) }

    func isSaving(_ ref: PlanSlotRef) -> Bool { savingSlots.contains(ref.id) }

    // MARK: Loading

    /// Loads a week. Without `force`, a week loaded in the last minute is left as is.
    func load(_ weekStart: String, force: Bool = false) async {
        if !force, weeks[weekStart] != nil, let last = loadedAt[weekStart], Date.now.timeIntervalSince(last) < 60 { return }
        guard !loadingWeeks.contains(weekStart) else { return }
        loadingWeeks.insert(weekStart)
        defer { loadingWeeks.remove(weekStart) }
        do {
            var fetched = try await KitchenStore.shared.currentPlan(weekStart: weekStart)
            // Keep edits that are still saving rather than flashing back to the old value.
            if let current = weeks[weekStart] {
                for id in savingSlots where id.hasPrefix(weekStart + "|") {
                    let parts = id.split(separator: "|").map(String.init)
                    guard parts.count == 3, let day = DayOfWeek(rawValue: parts[1]), let slot = MealSlotType(rawValue: parts[2]) else { continue }
                    fetched.set(current.slot(day, slot), day: day, slot: slot)
                }
            }
            weeks[weekStart] = fetched
            loadedAt[weekStart] = .now
            loadErrors[weekStart] = nil
            shareWithHearth()
        } catch is CancellationError {
            return
        } catch {
            if weeks[weekStart] == nil {
                loadErrors[weekStart] = FriendlyError.message(error, fallback: "This week's plan couldn't load. Try again.")
            }
        }
    }

    /// A plan the server just returned (after the AI planner saved it).
    func replace(_ planner: PlannerResponse) {
        weeks[planner.weekStart] = planner
        loadedAt[planner.weekStart] = .now
        loadErrors[planner.weekStart] = nil
        shareWithHearth()
    }

    /// The next `load` of this week goes to the server.
    func invalidate(_ weekStart: String) {
        loadedAt[weekStart] = nil
    }

    // MARK: Saving

    /// Shows `next` right away and sends `configure`'s update; the server's copy replaces it,
    /// or the old slot comes back if it fails.
    @discardableResult
    private func save(_ ref: PlanSlotRef, showing next: PlannerSlot, _ configure: (inout PlanSlotUpdate) -> Void) async -> Bool {
        let previous = slot(ref)
        setLocal(next, ref)
        var update = PlanSlotUpdate(weekStart: ref.weekStart, day: ref.day, slot: ref.slot)
        configure(&update)
        savingSlots.insert(ref.id)
        defer { savingSlots.remove(ref.id) }
        do {
            let response = try await KitchenStore.shared.updateSlot(update)
            setLocal(merged(response.slotData, keeping: next), ref)
            return true
        } catch {
            setLocal(previous, ref)
            if !(error is CancellationError) {
                actionError = FriendlyError.message(error)
            }
            return false
        }
    }

    private func setLocal(_ value: PlannerSlot, _ ref: PlanSlotRef) {
        weeks[ref.weekStart]?.set(value, day: ref.day, slot: ref.slot)
        shareWithHearth()
    }

    /// The other Hearth apps on this device (Caloma's calendar) see the plan too.
    private func shareWithHearth() {
        HearthPublisher.publishPlan(weeks: weeks)
    }

    /// The PUT response leaves out version details the GET computed; carry them over.
    private func merged(_ saved: PlannerSlot, keeping local: PlannerSlot) -> PlannerSlot {
        var result = saved
        result.recipeItems = saved.recipeItems.enumerated().map { index, item in
            guard index < local.recipeItems.count else { return item }
            let mine = local.recipeItems[index]
            guard mine.recipeId == item.recipeId, mine.title == item.title else { return item }
            var copy = item
            copy.currentVersionId = copy.currentVersionId ?? mine.currentVersionId
            copy.recipeStatus = copy.recipeStatus ?? mine.recipeStatus
            copy.hasUpdateAvailable = copy.hasUpdateAvailable ?? mine.hasUpdateAvailable
            copy.imageUrl = copy.imageUrl ?? mine.imageUrl
            return copy
        }
        return result
    }

    /// Saves the slot's recipe list (clearing any Dine Out), with the first title as the
    /// custom meal, as the Expo app did.
    @discardableResult
    private func saveItems(_ items: [PlannerMealItem], in ref: PlanSlotRef, completed: Bool) async -> Bool {
        let current = slot(ref)
        var next = current
        next.recipeItems = items
        next.dineOut = nil
        next.customMeal = items.first?.title
        next.completed = completed
        return await save(ref, showing: next) { update in
            update.customMeal = .some(items.first?.title)
            update.dineOut = .some(nil)
            update.recipeItems = items
            update.excludedMembers = current.excludedMembers
            update.completed = completed
        }
    }

    // MARK: Recipes

    /// Adds a recipe in a role. Returns false (with a message) when it's already there.
    @discardableResult
    func addRecipe(_ recipe: RecipeSummary, role: PlannerMealRole, to ref: PlanSlotRef) async -> Bool {
        let current = slot(ref)
        let title = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDuplicate = current.recipeItems.contains { item in
            (item.recipeId != nil && item.recipeId == recipe.id) || item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title.lowercased()
        }
        if isDuplicate {
            actionError = "\(recipe.title) is already planned for \(ref.title)."
            return false
        }
        let versionID = recipe.currentVersionId?.trimmingCharacters(in: .whitespaces)
        let pinned = (versionID?.isEmpty ?? true) ? nil : versionID
        let item = PlannerMealItem(
            title: recipe.title,
            role: role,
            imageUrl: recipe.imageUrl,
            recipeId: pinned != nil || KitchenStore.shared.isOwn(recipe.id) ? recipe.id : nil,
            recipeVersionId: pinned,
            source: pinned != nil || KitchenStore.shared.isOwn(recipe.id) ? "library" : "custom",
            recipeStatus: recipe.status,
            currentVersionId: pinned,
            hasUpdateAvailable: false
        )
        let items = (current.dineOut == nil ? current.recipeItems : []) + [item]
        return await saveItems(items, in: ref, completed: false)
    }

    func removeRecipe(at index: Int, in ref: PlanSlotRef) async {
        var items = slot(ref).recipeItems
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        await saveItems(items, in: ref, completed: slot(ref).completed)
    }

    func setRole(_ role: PlannerMealRole, at index: Int, in ref: PlanSlotRef) async {
        var items = slot(ref).recipeItems
        guard items.indices.contains(index), items[index].role != role else { return }
        items[index].role = role
        await saveItems(items, in: ref, completed: slot(ref).completed)
    }

    /// Moves a recipe up (-1) or down (+1) in the slot.
    func moveRecipe(at index: Int, by offset: Int, in ref: PlanSlotRef) async {
        var items = slot(ref).recipeItems
        let target = index + offset
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        items.swapAt(index, target)
        await saveItems(items, in: ref, completed: slot(ref).completed)
    }

    /// Pins the recipe's newest published version (the "Update available" badge).
    func useLatestVersion(at index: Int, in ref: PlanSlotRef) async {
        let items = slot(ref).recipeItems
        guard items.indices.contains(index), let recipeID = items[index].recipeId else { return }
        do {
            let detail = try await KitchenStore.shared.recipe(recipeID)
            let latest = detail.currentVersionId?.trimmingCharacters(in: .whitespaces) ?? ""
            var next = slot(ref).recipeItems
            guard next.indices.contains(index), next[index].recipeId == recipeID else { return }
            guard !latest.isEmpty, detail.status == .published, latest != next[index].recipeVersionId else {
                // Already current: just drop the badge.
                next[index].hasUpdateAvailable = false
                var local = slot(ref)
                local.recipeItems = next
                setLocal(local, ref)
                return
            }
            next[index].title = detail.title
            next[index].imageUrl = detail.imageUrl
            next[index].recipeVersionId = latest
            next[index].currentVersionId = latest
            next[index].recipeStatus = detail.status
            next[index].hasUpdateAvailable = false
            next[index].source = next[index].source ?? "library"
            await saveItems(next, in: ref, completed: slot(ref).completed)
        } catch is CancellationError {
            return
        } catch {
            actionError = FriendlyError.message(error)
        }
    }

    // MARK: Custom meals and Dine Out

    func setCustomMeal(_ text: String, in ref: PlanSlotRef) async {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !trimmed.isEmpty else {
            await clearMeal(in: ref)
            return
        }
        let current = slot(ref)
        var next = current
        next.customMeal = trimmed
        next.recipeItems = []
        next.dineOut = nil
        next.completed = false
        await save(ref, showing: next) { update in
            update.customMeal = .some(trimmed)
            update.dineOut = .some(nil)
            update.recipeItems = []
            update.excludedMembers = current.excludedMembers
            update.completed = false
        }
    }

    /// Clears the recipes, custom meal and Dine Out (snacks and who's eating stay).
    func clearMeal(in ref: PlanSlotRef) async {
        let current = slot(ref)
        var next = current
        next.customMeal = nil
        next.recipeItems = []
        next.dineOut = nil
        next.completed = false
        await save(ref, showing: next) { update in
            update.customMeal = .some(nil)
            update.dineOut = .some(nil)
            update.recipeItems = []
            update.excludedMembers = current.excludedMembers
            update.completed = false
        }
    }

    /// Empties the slot completely, snacks included.
    func clearSlot(_ ref: PlanSlotRef) async {
        let current = slot(ref)
        var next = current
        next.customMeal = nil
        next.recipeItems = []
        next.dineOut = nil
        next.snackItems = []
        next.completed = false
        await save(ref, showing: next) { update in
            update.customMeal = .some(nil)
            update.dineOut = .some(nil)
            update.recipeItems = []
            update.snackItems = []
            update.excludedMembers = current.excludedMembers
            update.completed = false
        }
    }

    func setDineOut(_ dineOut: PlannerDineOut, in ref: PlanSlotRef) async {
        let current = slot(ref)
        var next = current
        next.dineOut = dineOut
        next.customMeal = nil
        next.recipeItems = []
        next.completed = false
        await save(ref, showing: next) { update in
            update.customMeal = .some(nil)
            update.dineOut = .some(dineOut)
            update.recipeItems = []
            update.excludedMembers = current.excludedMembers
            update.completed = false
        }
    }

    func removeDineOut(in ref: PlanSlotRef) async {
        guard slot(ref).dineOut != nil else { return }
        await clearMeal(in: ref)
    }

    // MARK: Snacks

    func addSnacks(_ snacks: [PlannerSnackItem], to ref: PlanSlotRef) async {
        let current = slot(ref)
        let existing = Set(current.snackItems.map(\.offId))
        let added = snacks.filter { !existing.contains($0.offId) }
        guard !added.isEmpty else { return }
        var next = current
        next.snackItems = current.snackItems + added
        let items = next.snackItems
        await save(ref, showing: next) { update in
            update.snackItems = items
        }
    }

    func removeSnack(at index: Int, in ref: PlanSlotRef) async {
        var next = slot(ref)
        guard next.snackItems.indices.contains(index) else { return }
        next.snackItems.remove(at: index)
        let items = next.snackItems
        await save(ref, showing: next) { update in
            update.snackItems = items
        }
    }

    // MARK: Who's eating and cooked

    /// Includes or leaves out a person (by name, as the API stores them).
    func toggleExcluded(_ name: String, in ref: PlanSlotRef) async {
        let current = slot(ref)
        var excluded = current.excludedMembers
        if let index = excluded.firstIndex(of: name) {
            excluded.remove(at: index)
        } else {
            excluded.append(name)
        }
        var next = current
        next.excludedMembers = excluded
        await save(ref, showing: next) { update in
            update.excludedMembers = excluded
            update.completed = current.completed
        }
    }

    /// Marks the meal cooked (or not). Returns whether it saved.
    @discardableResult
    func setCompleted(_ completed: Bool, in ref: PlanSlotRef) async -> Bool {
        let current = slot(ref)
        var next = current
        next.completed = completed
        return await save(ref, showing: next) { update in
            update.excludedMembers = current.excludedMembers
            update.completed = completed
        }
    }
}

// MARK: - Ask BigTable

extension PlanStore {
    /// Puts a meal in a slot exactly as given (its recipes, custom meal or Dine Out), keeping
    /// who's eating and the snacks as they are now. Ask BigTable plans meals, and undoes and
    /// redoes them, with this. Returns whether it saved.
    @discardableResult
    func restoreMeal(_ meal: PlannerSlot, in ref: PlanSlotRef) async -> Bool {
        let current = slot(ref)
        var next = current
        next.customMeal = meal.customMeal
        next.recipeItems = meal.recipeItems
        next.dineOut = meal.dineOut
        next.completed = meal.completed
        return await save(ref, showing: next) { update in
            update.customMeal = .some(meal.customMeal)
            update.dineOut = .some(meal.dineOut)
            update.recipeItems = meal.recipeItems
            update.excludedMembers = current.excludedMembers
            update.completed = meal.completed
        }
    }
}
