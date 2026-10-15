import Foundation
import FoundationModels
import OSLog

// The tools Ask BigTable's model calls to read and change the household's plan, recipes and
// grocery list. The tools themselves run outside the main actor (FoundationModels calls them
// from its own tasks), so each one hands its work to `AskHousehold`, which runs on the main
// actor next to the stores.

// MARK: - Tools

nonisolated struct PlanLookupTool: Tool {
    let name = "getMealPlan"
    let description = "Gets what's planned for breakfast, lunch and dinner on a day or a week, and who isn't eating."
    let household: AskHousehold

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Which days to look at. Use \"this week\" when no day is named.", .anyOf(AskDay.rangeChoices))
        var days: String
        @Guide(description: "The meal they asked about, or all", .anyOf(AskDay.lookupMealChoices))
        var meal: String
    }

    func call(arguments: Arguments) async throws -> String {
        let days = arguments.days
        let meal = arguments.meal
        return await household.planText(days: days, meal: meal)
    }
}

nonisolated struct RecipeSearchTool: Tool {
    let name = "findRecipes"
    let description = "Searches the family's recipes by name or keywords, like \"tacos\" or \"chicken\"."
    let household: AskHousehold

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "A recipe name or a few keywords")
        var search: String
    }

    func call(arguments: Arguments) async throws -> String {
        let search = arguments.search
        return await household.recipesText(matching: search)
    }
}

nonisolated struct PlanMealTool: Tool {
    let name = "planMeal"
    let description = "Puts a meal on the plan for a day: one of the family's recipes (found by name) or a simple meal like \"Leftovers\". Won't replace a planned meal unless told to."
    let household: AskHousehold

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The day", .anyOf(AskDay.dayChoices))
        var day: String
        @Guide(description: "True only for a day next week, like \"next Tuesday\"")
        var nextWeek: Bool
        @Guide(description: "The meal", .anyOf(AskDay.mealChoices))
        var meal: String
        @Guide(description: "What to eat: a recipe's name like \"Chicken Street Tacos\", or a meal like \"Leftovers\" or \"Pizza night\"")
        var dish: String
        @Guide(description: "True only when the person clearly said to replace the meal already planned there")
        var replace: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        let day = arguments.day
        let nextWeek = arguments.nextWeek
        let meal = arguments.meal
        let dish = arguments.dish
        let replace = arguments.replace
        return await household.planMeal(day: day, nextWeek: nextWeek, meal: meal, dish: dish, replace: replace)
    }
}

/// One thing to add to the grocery list.
@Generable
nonisolated struct AskGroceryRequest {
    @Guide(description: "The item's name, like \"Limes\" or \"Flour tortillas\"")
    var name: String
    @Guide(description: "How much, like \"6\" or \"2 packs\". Empty when not said.")
    var quantity: String
    @Guide(description: "The store aisle it's found in", .anyOf(AskDay.aisles))
    var aisle: String
}

/// What `AddGroceryTool` passes to the main actor.
nonisolated struct AskGroceryInput: Sendable {
    var name: String
    var quantity: String
    var aisle: String
}

nonisolated struct AddGroceryTool: Tool {
    let name = "addGroceryItems"
    let description = "Adds things to the household's grocery list right away, and says which were already on it."
    let household: AskHousehold

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Each thing to add")
        var items: [AskGroceryRequest]
    }

    func call(arguments: Arguments) async throws -> String {
        let items = arguments.items.map { AskGroceryInput(name: $0.name, quantity: $0.quantity, aisle: $0.aisle) }
        return await household.addGroceries(items)
    }
}

nonisolated struct CheckOffGroceryTool: Tool {
    let name = "checkOffGroceryItems"
    let description = "Checks things off the grocery list right away, when they got them or want them crossed off."
    let household: AskHousehold

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The things to check off, like \"milk\" or \"eggs\"")
        var names: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        let names = arguments.names
        return await household.checkOff(names)
    }
}

nonisolated struct GroceryListTool: Tool {
    let name = "getGroceryList"
    let description = "Gets what's still needed on the grocery list, by aisle, and how many things are left."
    let household: AskHousehold

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "One aisle they asked about, or all", .anyOf(AskDay.sectionChoices))
        var section: String
    }

    func call(arguments: Arguments) async throws -> String {
        let section = arguments.section
        return await household.groceryText(section: section)
    }
}

// MARK: - Days and names

/// The words the model may use for days, meals and aisles, and what they mean.
nonisolated enum AskDay {
    static let weekdays = DayOfWeek.allCases.map(\.rawValue)
    static let dayChoices = ["today", "tomorrow"] + weekdays
    static let rangeChoices = ["today", "tomorrow", "this week", "rest of this week", "next week"] + weekdays
    static let mealChoices = ["breakfast", "lunch", "dinner"]
    static let lookupMealChoices = ["all", "breakfast", "lunch", "dinner"]
    /// GroceryStore's default aisles.
    static let aisles = ["Produce", "Meat", "Dairy", "Pantry", "Bakery", "Frozen", "Beverages", "Snacks", "Household", "Other"]
    static let sectionChoices = ["all"] + aisles

    /// The Sunday starting the week of a "YYYY-MM-DD" day.
    static func weekStart(of iso: String) -> String {
        ISODay.weekStart(containing: ISODay.date(from: iso) ?? .now)
    }

    static func ref(iso: String, slot: MealSlotType) -> PlanSlotRef {
        PlanSlotRef(weekStart: weekStart(of: iso), day: PlanDates.day(forISO: iso), slot: slot)
    }

    /// The day ("YYYY-MM-DD") for "today", "tomorrow" or a weekday. A weekday is the next one
    /// coming (today counts); with `nextWeek`, it's that day in next week.
    static func iso(for word: String, nextWeek: Bool) -> String? {
        let today = PlanDates.todayISO
        switch word.trimmingCharacters(in: .whitespaces).lowercased() {
        case "today", "tonight":
            return today
        case "tomorrow":
            return ISODay.adding(days: 1, to: today)
        case let key:
            guard let target = DayOfWeek(rawValue: key) else { return nil }
            if nextWeek {
                return PlanDates.iso(weekStart: ISODay.adding(days: 7, to: weekStart(of: today)), day: target)
            }
            let ahead = (target.offset - PlanDates.day(forISO: today).offset + 7) % 7
            return ISODay.adding(days: ahead, to: today)
        }
    }

    /// The days for a lookup: one day, the rest of this week, this week or next week.
    static func dates(for word: String) -> [String] {
        let today = PlanDates.todayISO
        let thisWeek = weekStart(of: today)
        switch word.trimmingCharacters(in: .whitespaces).lowercased() {
        case "this week":
            return PlanDates.dates(from: thisWeek, to: ISODay.adding(days: 6, to: thisWeek))
        case "rest of this week":
            return PlanDates.dates(from: today, to: ISODay.adding(days: 6, to: thisWeek))
        case "next week":
            let next = ISODay.adding(days: 7, to: thisWeek)
            return PlanDates.dates(from: next, to: ISODay.adding(days: 6, to: next))
        case let key:
            return iso(for: key, nextWeek: false).map { [$0] } ?? []
        }
    }

    /// One of the default aisles, or Other.
    static func aisle(_ name: String) -> String {
        aisles.first { $0.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame } ?? "Other"
    }
}

/// Loose name matching for "we got the milk" against "Milk", or "tacos" against "Chicken Street
/// Tacos": case, accents, plurals and small words don't matter.
nonisolated enum AskMatch {
    private static let ignored: Set<String> = ["the", "a", "an", "some", "of", "and", "our", "my", "for", "with", "to"]

    static func words(_ text: String) -> [String] {
        AskText.words(text).filter { !ignored.contains($0) }.map { singular($0) }
    }

    static func singular(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("oes") || word.hasSuffix("ches") || word.hasSuffix("shes") { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    /// 3: the same name. 2: every word of the name was said ("2 gallons of milk" for "Milk").
    /// 1: every word said is in the name ("tortillas" for "Flour tortillas"). 0: no match.
    static func score(_ query: String, _ name: String) -> Int {
        let said = Set(words(query))
        let named = Set(words(name))
        guard !said.isEmpty, !named.isEmpty else { return 0 }
        if said == named { return 3 }
        if named.isSubset(of: said) { return 2 }
        if said.isSubset(of: named) { return 1 }
        return 0
    }
}

// MARK: - The household, on the main actor

/// What the tools read and change: the plan (PlanStore), the family's recipes (the API) and the
/// grocery list (GroceryStore). Every change is also recorded as a card for the reply, so it
/// can be undone.
final class AskHousehold {
    /// Cards for the reply being written.
    private(set) var actions: [AskAction] = []
    /// The grocery aisle this reply was about.
    private(set) var focusSection: String?

    private var plan: PlanStore { PlanStore.shared }
    private var grocery: GroceryStore { GroceryStore.shared }
    private let api = BigTableAPI.shared
    private let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "ask")

    func beginTurn() {
        actions = []
        focusSection = nil
    }

    func takeActions() -> [AskAction] {
        let taken = actions
        actions = []
        return taken
    }

    private func record(_ kind: AskAction.Kind) {
        actions.append(AskAction(kind: kind))
    }

    /// This week's plan and the grocery list, for the suggestions and the first answer.
    func prepare() async {
        await plan.load(PlanDates.currentWeekStart)
        await loadGrocery()
    }

    private func loadGrocery() async {
        if !grocery.hasLoaded { await grocery.load() }
    }

    // MARK: Plan

    func planText(days word: String, meal: String) async -> String {
        let dates = AskDay.dates(for: word)
        guard !dates.isEmpty else {
            return "That day wasn't understood. Ask about today, tomorrow, a weekday, this week or next week."
        }
        for weekStart in Set(dates.map { AskDay.weekStart(of: $0) }).sorted() {
            await plan.load(weekStart)
        }
        let asked = MealSlotType(rawValue: meal.lowercased())
        let slots: [MealSlotType] = asked.map { [$0] } ?? MealSlotType.allCases
        let cardSlot = asked ?? .dinner
        let today = PlanDates.todayISO
        var lines: [String] = []
        var rows: [AskWeekCard.Row] = []
        for iso in dates {
            let ref = AskDay.ref(iso: iso, slot: cardSlot)
            let label = PlanDates.shortTitle(iso: iso) + (iso == today ? " (today)" : "")
            guard let planner = plan.planner(ref.weekStart) else {
                lines.append("\(label): the plan couldn't be loaded")
                continue
            }
            let parts = slots.map { slot -> String in
                let planned = planner.slot(ref.day, slot)
                guard !planned.isEmpty else { return "\(slot.rawValue): nothing planned" }
                var text = "\(slot.rawValue): \(planned.title)"
                if !planned.excludedMembers.isEmpty {
                    text += " (not eating: \(planned.excludedMembers.joined(separator: ", ")))"
                }
                return text
            }
            lines.append("\(label): " + parts.joined(separator: "; "))
            let shown = planner.slot(ref.day, cardSlot)
            rows.append(AskWeekCard.Row(day: ref.day.short.uppercased(), title: shown.isEmpty ? nil : shown.title, imageUrl: shown.recipeItems.first?.imageUrl))
        }
        if rows.count >= 3 {
            actions.removeAll { action in
                if case .week = action.kind { return true }
                return false
            }
            record(.week(AskWeekCard(rows: rows)))
        }
        return lines.joined(separator: "\n")
    }

    func planMeal(day word: String, nextWeek: Bool, meal: String, dish: String, replace: Bool) async -> String {
        guard AppModel.shared.canManagePlan else {
            return "Nothing was changed: the household organizer hasn't allowed this person to change the meal plan."
        }
        guard let iso = AskDay.iso(for: word, nextWeek: nextWeek) else {
            return "That day wasn't understood, so nothing was changed."
        }
        let name = dish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "No meal was named, so nothing was changed." }
        let slot = MealSlotType(rawValue: meal.lowercased()) ?? .dinner
        let ref = AskDay.ref(iso: iso, slot: slot)
        await plan.load(ref.weekStart)
        guard plan.planner(ref.weekStart) != nil else {
            return "The plan couldn't be loaded, so nothing was changed."
        }
        let current = plan.slot(ref)
        let recipe = await findRecipe(named: name)
        let planned = Self.meal(recipe: recipe, custom: name, keeping: current)
        let title = recipe?.title ?? String(name.prefix(120))
        let when = "\(PlanDates.shortTitle(iso: iso)) \(slot.rawValue)"

        if !current.isEmpty, AskMatch.score(title, current.title) == 3 {
            return "\(current.title) is already planned for \(when). Nothing was changed."
        }
        var change = AskPlanChange(
            ref: ref,
            title: title,
            imageUrl: recipe?.imageUrl,
            detail: Self.detail(ref, excluded: current.excludedMembers),
            before: current,
            after: planned,
            existingTitle: current.isEmpty ? nil : current.title,
            status: .needsConfirmation
        )
        if !current.isEmpty, !replace {
            record(.plan(change))
            return "\(when) already has \(current.title). Nothing was changed yet: it needs confirmation. Ask whether to replace it with \(title). They can tap Replace or Keep, or say so."
        }
        guard await plan.restoreMeal(planned, in: ref) else {
            let reason = plan.actionError ?? "it didn't save"
            plan.actionError = nil
            return "\(title) couldn't be put on the plan (\(reason)). Nothing was changed."
        }
        change.after = plan.slot(ref)
        change.status = .done
        record(.plan(change))
        let replaced = current.isEmpty ? "" : ", replacing \(current.title)"
        return "Planned \(title) for \(when)\(replaced)."
    }

    /// Replace or Keep on a meal that was already planned. Nil when it couldn't be saved.
    func resolve(_ change: AskPlanChange, replace: Bool) async -> AskPlanChange? {
        var change = change
        guard replace else {
            change.status = .kept
            return change
        }
        guard AppModel.shared.canManagePlan else { return nil }
        await plan.load(change.ref.weekStart)
        change.before = plan.slot(change.ref)
        guard await plan.restoreMeal(change.after, in: change.ref) else {
            plan.actionError = nil
            return nil
        }
        change.after = plan.slot(change.ref)
        change.status = .done
        return change
    }

    /// "Thursday dinner · serves 8".
    private static func detail(_ ref: PlanSlotRef, excluded: [String]) -> String {
        let eating = AppModel.shared.members.count - excluded.count
        return eating > 0 ? "\(ref.title) · serves \(eating)" : ref.title
    }

    /// The slot with this meal in it (who's eating and the snacks stay as they were).
    private static func meal(recipe: RecipeSummary?, custom: String, keeping current: PlannerSlot) -> PlannerSlot {
        var next = current
        next.dineOut = nil
        next.completed = false
        if let recipe {
            // Pinned to the recipe's current version, as when it's added in the Plan tab.
            let version = recipe.currentVersionId?.trimmingCharacters(in: .whitespaces)
            let pinned = (version?.isEmpty ?? true) ? nil : version
            next.recipeItems = [PlannerMealItem(
                title: recipe.title,
                role: .entree,
                imageUrl: recipe.imageUrl,
                recipeId: pinned == nil ? nil : recipe.id,
                recipeVersionId: pinned,
                source: pinned == nil ? "custom" : "library",
                recipeStatus: recipe.status,
                currentVersionId: pinned,
                hasUpdateAvailable: false
            )]
            next.customMeal = recipe.title
        } else {
            next.recipeItems = []
            next.customMeal = String(custom.prefix(120))
        }
        return next
    }

    // MARK: Recipes

    func recipesText(matching search: String) async -> String {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Nothing to search for." }
        do {
            var found = try await api.recipes(query: query, collection: "my", limit: 8).recipes
            var source = "The family's recipes"
            if found.isEmpty {
                found = try await api.recipes(query: query, limit: 5).recipes
                source = "None of the family's own recipes match. From BigTable's recipes"
            }
            guard !found.isEmpty else { return "No recipes match \"\(query)\"." }
            let lines = found.map { recipe -> String in
                var facts: [String] = []
                if !recipe.tags.isEmpty { facts.append(recipe.tags.prefix(4).joined(separator: ", ")) }
                if recipe.totalMinutes > 0 { facts.append(durationText(minutes: recipe.totalMinutes)) }
                return facts.isEmpty ? "- \(recipe.title)" : "- \(recipe.title) (\(facts.joined(separator: "; ")))"
            }
            return "\(source):\n" + lines.joined(separator: "\n")
        } catch {
            log.error("Ask recipe search failed: \(error.localizedDescription, privacy: .public)")
            return "The recipes couldn't be loaded right now."
        }
    }

    /// The family's recipe that best matches a dish's name (then BigTable's), or nil to plan it
    /// as a simple meal.
    private func findRecipe(named dish: String) async -> RecipeSummary? {
        for collection in ["my", nil] as [String?] {
            guard let found = try? await api.recipes(query: dish, collection: collection, limit: 8).recipes else { continue }
            let scored = found.map { (recipe: $0, score: AskMatch.score(dish, $0.title)) }.filter { $0.score > 0 }
            if let best = scored.max(by: { $0.score < $1.score }) { return best.recipe }
        }
        return nil
    }

    // MARK: Grocery list

    func addGroceries(_ requests: [AskGroceryInput]) async -> String {
        guard AppModel.shared.isOrganizer else {
            return "Nothing was added: only the household organizer can add to the grocery list. Everyone can check things off."
        }
        await loadGrocery()
        guard grocery.hasLoaded else { return "The grocery list couldn't be loaded, so nothing was added." }
        var added: [AskGroceryLine] = []
        var already: [String] = []
        for request in requests.prefix(15) {
            let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let existing = bestItem(for: name, minimum: 2) {
                already.append(grocery.isChecked(existing.item) ? "\(existing.item.name) (checked off)" : existing.item.name)
                continue
            }
            let section = AskDay.aisle(request.aisle)
            let quantity = request.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = addItem(name: name, quantity: quantity, section: section) else { continue }
            let item = grocery.allItems.first { $0.id == id }
            added.append(AskGroceryLine(itemID: id, name: item?.name ?? name, quantity: item?.quantity ?? quantity, section: section))
        }
        if !added.isEmpty {
            record(.groceryAdd(AskGroceryChange(items: added)))
            focusSection = added.first?.section
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("Added \(added.map(\.name).joined(separator: ", ")) to the grocery list.") }
        if !already.isEmpty { parts.append("Already on the list: \(already.joined(separator: ", ")).") }
        return parts.isEmpty ? "Nothing was added." : parts.joined(separator: " ")
    }

    func checkOff(_ names: [String]) async -> String {
        await loadGrocery()
        guard grocery.hasList, !grocery.isEmpty else { return "There's nothing on the grocery list yet." }
        var lines: [AskGroceryLine] = []
        var already: [String] = []
        var missing: [String] = []
        for raw in names.prefix(20) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard let match = bestItem(for: name, minimum: 1) else {
                missing.append(name)
                continue
            }
            if lines.contains(where: { $0.itemID == match.item.id }) { continue }
            if grocery.isChecked(match.item) {
                already.append(match.item.name)
                continue
            }
            grocery.toggle(match.item)
            lines.append(AskGroceryLine(itemID: match.item.id, name: match.item.name, quantity: match.item.quantity, section: match.section))
        }
        if !lines.isEmpty {
            record(.groceryCheck(AskGroceryChange(items: lines)))
            focusSection = lines.first?.section
        }
        var parts: [String] = []
        if !lines.isEmpty { parts.append("Checked off \(lines.map(\.name).joined(separator: ", ")).") }
        if !already.isEmpty { parts.append("Already checked off: \(already.joined(separator: ", ")).") }
        if !missing.isEmpty { parts.append("Not on the list: \(missing.joined(separator: ", ")).") }
        parts.append(remainingSummary())
        return parts.joined(separator: " ")
    }

    func groceryText(section: String) async -> String {
        await loadGrocery()
        guard grocery.hasLoaded else { return "The grocery list couldn't be loaded." }
        guard grocery.hasList, !grocery.isEmpty else { return "The grocery list is empty." }
        let wanted = section.lowercased() == "all" ? nil : section
        var lines = ["\(grocery.remainingCount) of \(grocery.totalCount) things still needed."]
        var listed = 0
        var found = false
        for aisle in grocery.orderedSections {
            if let wanted, aisle.name.caseInsensitiveCompare(wanted) != .orderedSame { continue }
            found = true
            let needed = aisle.items.filter { item in !grocery.isChecked(item) }
            guard !needed.isEmpty else {
                if wanted != nil { lines.append("\(aisle.name): everything is checked off.") }
                continue
            }
            if focusSection == nil || wanted != nil { focusSection = aisle.name }
            // The on-device model has a small context: list at most 40 things.
            let room = max(0, 40 - listed)
            let shown = needed.prefix(room).map { item in
                item.quantity.isEmpty ? item.name : "\(item.name) (\(item.quantity))"
            }
            listed += shown.count
            var line = "\(aisle.name): " + (shown.isEmpty ? "" : shown.joined(separator: ", "))
            if needed.count > shown.count { line += "\(shown.isEmpty ? "" : ", and ")\(needed.count - shown.count) more" }
            lines.append(line)
        }
        if let wanted, !found { lines.append("There's no \(wanted) section on the list.") }
        return lines.joined(separator: "\n")
    }

    /// "14 things left, most in Pantry."
    private func remainingSummary() -> String {
        let left = grocery.remainingCount
        guard left > 0 else { return "Everything on the list is checked off." }
        let counts = grocery.orderedSections
            .map { aisle in (name: aisle.name, left: aisle.items.filter { item in !grocery.isChecked(item) }.count) }
            .filter { $0.left > 0 }
        var text = "\(left) \(left == 1 ? "thing" : "things") left"
        if let top = counts.max(by: { $0.left < $1.left }) {
            text += counts.count == 1 ? ", all in \(top.name)" : ", most in \(top.name)"
        }
        return text + "."
    }

    /// The list item that best matches a name, preferring ones not checked off yet.
    private func bestItem(for name: String, minimum: Int) -> (item: GroceryItem, section: String)? {
        var best: (item: GroceryItem, section: String, rank: Int)?
        for aisle in grocery.sections {
            for item in aisle.items {
                let score = AskMatch.score(name, item.name)
                guard score >= minimum else { continue }
                let rank = score * 2 + (grocery.isChecked(item) ? 0 : 1)
                if best == nil || rank > best!.rank { best = (item, aisle.name, rank) }
            }
        }
        return best.map { (item: $0.item, section: $0.section) }
    }

    /// Adds an item and returns its id on the list.
    private func addItem(name: String, quantity: String, section: String) -> String? {
        let before = Set(grocery.allItems.map(\.id))
        grocery.addItem(name: name, quantity: quantity, to: section)
        return grocery.allItems.first { !before.contains($0.id) }?.id
    }

    private func setChecked(_ id: String, _ checked: Bool) {
        guard let item = grocery.allItems.first(where: { $0.id == id }), grocery.isChecked(item) != checked else { return }
        grocery.toggle(item)
    }

    // MARK: Undo and Redo

    /// Reverses (or redoes) a card's change. Nil when it couldn't be saved.
    func toggle(_ kind: AskAction.Kind) async -> AskAction.Kind? {
        switch kind {
        case .week:
            return kind
        case .plan(var change):
            switch change.status {
            case .done:
                guard await plan.restoreMeal(change.before, in: change.ref) else {
                    plan.actionError = nil
                    return nil
                }
                change.status = .undone
            case .undone:
                guard await plan.restoreMeal(change.after, in: change.ref) else {
                    plan.actionError = nil
                    return nil
                }
                change.status = .done
            case .needsConfirmation, .kept:
                break
            }
            return .plan(change)
        case .groceryAdd(var change):
            await loadGrocery()
            if change.undone {
                for index in change.items.indices {
                    let line = change.items[index]
                    if let id = addItem(name: line.name, quantity: line.quantity, section: line.section) {
                        change.items[index].itemID = id
                    }
                }
            } else {
                for line in change.items where grocery.allItems.contains(where: { $0.id == line.itemID }) {
                    grocery.deleteItem(line.itemID)
                }
            }
            change.undone.toggle()
            return .groceryAdd(change)
        case .groceryCheck(var change):
            await loadGrocery()
            // Undo puts them back on the list; Redo checks them off again.
            for line in change.items { setChecked(line.itemID, change.undone) }
            change.undone.toggle()
            return .groceryCheck(change)
        }
    }
}
