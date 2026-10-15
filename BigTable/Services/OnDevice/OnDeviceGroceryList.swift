import Foundation
import FoundationModels
import OSLog

/// Builds the AI grocery list on the device: the planned meals and their recipes come from
/// the API as usual, the ingredient totals are added up here (a port of the API's
/// buildIngredientNeeds, scaled to who's eating), and Apple's on-device model sorts each item
/// into a store section and says how many to buy. A port of /api/ai/grocery-list.
///
/// Returns nil when the phone can't (no Apple Intelligence) or the plan has no recipes with
/// ingredients, and the caller asks the API instead.
enum OnDeviceGroceryList {
    nonisolated private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "OnDeviceGrocery")
    nonisolated private static let batchSize = 30

    /// One ingredient added up across the planned meals.
    nonisolated struct Need: Sendable {
        var name: String
        var unit: String?
        var total: Double?
        var occurrences: Int
        var recipes: [String]
    }

    private struct PlannedRecipe: Hashable {
        var recipeId: String
        var versionId: String?
        var title: String
        var eaters: Int
    }

    /// AI grocery lists are part of Pro; free accounts still go to the API, which answers
    /// with the paywall as before.
    static var canGenerate: Bool {
        OnDeviceRecipeParser.isAvailable && AppModel.shared.usage?.tier == "pro"
    }

    static func generate(dates: [String], costcoMode: Bool, note: String?) async throws -> GroceryListResponse.List? {
        guard canGenerate, !dates.isEmpty else { return nil }
        let householdSize = max(AppModel.shared.members.count, 1)
        let planned = try await plannedRecipes(on: Set(dates), householdSize: householdSize)
        guard !planned.isEmpty else { return nil }
        let needs = try await ingredientNeeds(for: planned)
        guard !needs.isEmpty else { return nil }

        var items: [(section: Section, item: GroceryItem)] = []
        for start in stride(from: 0, to: needs.count, by: batchSize) {
            let batch = Array(needs[start..<min(start + batchSize, needs.count)])
            items += await sort(batch, costcoMode: costcoMode, note: note)
        }
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items += await extras(from: note, costcoMode: costcoMode)
        }
        let sections = assemble(items)
        guard !sections.isEmpty else { return nil }
        let count = sections.reduce(0) { $0 + $1.items.count }
        return GroceryListResponse.List(sections: sections, estimatedCost: Double(max(60, count * 6 + 35)))
    }

    // MARK: The plan

    /// The recipes planned on these days, with how many are eating each meal.
    private static func plannedRecipes(on dates: Set<String>, householdSize: Int) async throws -> [PlannedRecipe] {
        let weekStarts = Set(dates.compactMap { ISODay.date(from: $0).map { ISODay.weekStart(containing: $0) } })
        var planned: [PlannedRecipe] = []
        for weekStart in weekStarts.sorted() {
            let plan = try await BigTableAPI.shared.currentPlan(weekStart: weekStart)
            for (index, day) in DayOfWeek.allCases.enumerated() where dates.contains(ISODay.adding(days: index, to: plan.weekStart)) {
                for slotType in MealSlotType.allCases {
                    let slot = plan.slot(day, slotType)
                    let eaters = max(1, householdSize - slot.excludedMembers.count)
                    for item in slot.recipeItems {
                        guard let recipeId = item.recipeId, !recipeId.isEmpty else { continue }
                        planned.append(PlannedRecipe(recipeId: recipeId, versionId: item.recipeVersionId, title: item.title, eaters: eaters))
                    }
                }
            }
        }
        return planned
    }

    /// Ingredients added up across the meals, each recipe scaled from its servings to the
    /// number eating.
    private static func ingredientNeeds(for planned: [PlannedRecipe]) async throws -> [Need] {
        nonisolated struct Key: Hashable, Sendable { var id: String; var version: String? }
        let keys = Set(planned.map { Key(id: $0.recipeId, version: $0.versionId) })
        let details = try await withThrowingTaskGroup(of: (Key, RecipeDetail?).self) { group in
            for key in keys {
                group.addTask { (key, try? await BigTableAPI.shared.recipe(key.id, versionId: key.version)) }
            }
            var found: [Key: RecipeDetail] = [:]
            for try await (key, detail) in group { if let detail { found[key] = detail } }
            return found
        }

        var order: [String] = []
        var needs: [String: Need] = [:]
        for meal in planned {
            guard let recipe = details[Key(id: meal.recipeId, version: meal.versionId)] else { continue }
            let scale = Double(max(meal.eaters, 1)) / max(recipe.baseServings, 1)
            for ingredient in recipe.ingredients {
                let name = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let unit = ingredient.measurementType?.trimmingCharacters(in: .whitespaces).lowercased()
                let key = "\(name.lowercased())::\(unit ?? "")"
                var need = needs[key] ?? Need(name: name, unit: (unit?.isEmpty ?? true) ? nil : unit, total: 0, occurrences: 0, recipes: [])
                if needs[key] == nil { order.append(key) }
                need.occurrences += 1
                if !need.recipes.contains(recipe.title) { need.recipes.append(recipe.title) }
                if let amount = ingredient.amount, let total = need.total {
                    need.total = total + amount * scale
                } else {
                    need.total = nil
                }
                needs[key] = need
            }
        }
        return order.compactMap { needs[$0] }
    }

    // MARK: Sections and quantities

    /// The store sections the app uses, in shopping order.
    enum Section: String, CaseIterable {
        case produce = "Produce", meat = "Meat", dairy = "Dairy", pantry = "Pantry", bakery = "Bakery"
        case frozen = "Frozen", beverages = "Beverages", snacks = "Snacks", household = "Household", other = "Other"

        var icon: String {
            switch self {
            case .produce: "🥬"
            case .meat: "🥩"
            case .dairy: "🥛"
            case .pantry: "🥫"
            case .bakery: "🥖"
            case .frozen: "❄️"
            case .beverages: "🥤"
            case .snacks: "🍿"
            case .household: "🧽"
            case .other: "🛒"
            }
        }

        init(_ section: GroceryAisle) {
            self = Section(rawValue: section.rawValue.capitalized) ?? .other
        }
    }

    private static func sort(_ batch: [Need], costcoMode: Bool, note: String?) async -> [(section: Section, item: GroceryItem)] {
        let lines = batch.enumerated().map { index, need in
            "\(index + 1). \(need.name): \(amountText(need)) (for \(need.recipes.prefix(3).joined(separator: ", ")))"
        }
        var instructions = [
            "You write grocery lists for a large family.",
            "For each numbered ingredient, choose its store section and how many to buy: a whole number of the packages, bunches, cans or items a shopper picks up, not the recipe amount. For example, 3 cups of flour is 1 bag, 6 cloves of garlic is 1 head, 2.5 lb of chicken is 1 or 2 packs.",
            "Keep the ingredient's name as a short shopping name, like \"Yellow onions\" or \"Shredded cheddar\".",
            "Give one entry for every numbered ingredient, with its number.",
        ]
        if costcoMode {
            instructions.append("They shop at a warehouse store like Costco: count the large warehouse packages to buy, and mark bulk when the warehouse size is the better buy.")
        }
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            instructions.append("The shopper's note: \(note). Mark skip for any ingredient the note says they already have or don't want.")
        }
        let session = LanguageModelSession(instructions: instructions.joined(separator: "\n"))
        var sorted: [Int: SortedGroceryItem] = [:]
        do {
            let response = try await session.respond(
                to: "Ingredients:\n" + lines.joined(separator: "\n"),
                generating: SortedGroceryList.self,
                options: GenerationOptions(temperature: 0.1)
            )
            for entry in response.content.items where (1...batch.count).contains(entry.number) {
                sorted[entry.number] = entry
            }
        } catch {
            log.notice("On-device grocery sorting used keywords instead: \(String(describing: error), privacy: .public)")
        }

        return batch.enumerated().compactMap { index, need in
            let meals = Array(need.recipes.prefix(4))
            if let entry = sorted[index + 1] {
                if entry.skip { return nil }
                let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let item = GroceryItem(
                    name: name.isEmpty ? need.name : name,
                    quantity: String(min(max(entry.quantity, 1), 99)),
                    meals: meals,
                    bulk: costcoMode && entry.bulk
                )
                return (Section(entry.section), item)
            }
            return (keywordSection(need.name), GroceryItem(name: need.name, quantity: fallbackQuantity(need), meals: meals, bulk: costcoMode))
        }
    }

    /// Things the shopper's note asks to add ("paper towels and milk").
    private static func extras(from note: String, costcoMode: Bool) async -> [(section: Section, item: GroceryItem)] {
        let session = LanguageModelSession(instructions: "You add things to a family's grocery list. List only the items this note asks to add or buy, with their store section and how many to buy. If it doesn't ask to add anything, return no items.")
        do {
            let response = try await session.respond(to: "The note: \(note)", generating: GroceryAdditions.self, options: GenerationOptions(temperature: 0.1))
            return response.content.items.compactMap { entry in
                let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return (Section(entry.section), GroceryItem(name: name, quantity: String(min(max(entry.quantity, 1), 99)), meals: [], bulk: costcoMode))
            }
        } catch {
            return []
        }
    }

    /// Sections in shopping order, items merged by name and sorted, ids like the API's.
    private static func assemble(_ entries: [(section: Section, item: GroceryItem)]) -> [GrocerySection] {
        var bySection: [Section: [String: GroceryItem]] = [:]
        for (section, item) in entries {
            let key = slug(item.name)
            guard !key.isEmpty else { continue }
            var items = bySection[section] ?? [:]
            if var existing = items[key] {
                existing.quantity = String((Int(existing.quantity) ?? 1) + (Int(item.quantity) ?? 1))
                existing.meals = Array((existing.meals + item.meals.filter { !existing.meals.contains($0) }).prefix(4))
                existing.bulk = existing.bulk || item.bulk
                items[key] = existing
            } else {
                var item = item
                item.id = "\(slug(section.rawValue)):\(key)"
                items[key] = item
            }
            bySection[section] = items
        }
        return Section.allCases.compactMap { section in
            guard let items = bySection[section], !items.isEmpty else { return nil }
            return GrocerySection(
                name: section.rawValue,
                icon: section.icon,
                items: items.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            )
        }
    }

    // MARK: Without the model

    private static func amountText(_ need: Need) -> String {
        guard let total = need.total, total > 0 else { return "some, in \(need.occurrences) recipe\(need.occurrences == 1 ? "" : "s")" }
        let amount = Ingredients.formatAmount((total * 100).rounded() / 100)
        return [amount, need.unit].compactMap { $0 }.joined(separator: " ")
    }

    /// Counted things ("4 eggs") round up; measured ones ("2 cups") are one package.
    private static func fallbackQuantity(_ need: Need) -> String {
        guard let total = need.total, total > 0 else { return "1" }
        let counted = need.unit == nil || ["clove", "cloves", "piece", "pieces", "whole", "can", "cans", "package", "packages"].contains(need.unit!)
        return String(counted ? min(Int(total.rounded(.up)), 99) : 1)
    }

    /// The API's keyword sections, for items the model didn't answer.
    private static func keywordSection(_ name: String) -> Section {
        let name = name.lowercased()
        let rules: [(Section, [String])] = [
            (.produce, ["onion", "garlic", "potato", "carrot", "pepper", "tomato", "spinach", "lettuce", "lemon", "lime", "apple", "banana", "avocado", "broccoli", "cabbage", "celery", "cucumber", "cilantro", "parsley", "basil"]),
            (.meat, ["chicken", "beef", "pork", "turkey", "salmon", "fish", "shrimp", "sausage", "bacon", "ham"]),
            (.dairy, ["milk", "cream", "cheese", "yogurt", "butter", "egg"]),
            (.bakery, ["bread", "bagel", "bun", "roll", "tortilla", "croissant", "muffin"]),
            (.frozen, ["frozen"]),
            (.beverages, ["juice", "soda", "coffee", "tea", "drink", "sparkling"]),
            (.snacks, ["chip", "cracker", "cookie", "pretzel", "popcorn", "snack", "granola bar"]),
            (.household, ["detergent", "soap", "paper towel", "toilet paper", "trash bag", "cleaner", "sponge"]),
        ]
        for (section, words) in rules where words.contains(where: { name.contains($0) }) { return section }
        return .pantry
    }

    private static func slug(_ value: String) -> String {
        value.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
    }
}

/// The store sections the model chooses from.
@Generable
nonisolated enum GroceryAisle: String {
    case produce, meat, dairy, pantry, bakery, frozen, beverages, snacks, household, other
}

@Generable
nonisolated struct SortedGroceryItem {
    @Guide(description: "The ingredient's number from the list")
    var number: Int
    @Guide(description: "A short shopping name")
    var name: String
    var section: GroceryAisle
    @Guide(description: "How many packages or items to buy, at least 1")
    var quantity: Int
    @Guide(description: "True when the warehouse-size package is the better buy")
    var bulk: Bool
    @Guide(description: "True when the shopper's note says they already have it or don't want it")
    var skip: Bool
}

@Generable
nonisolated struct SortedGroceryList {
    @Guide(description: "One entry per numbered ingredient")
    var items: [SortedGroceryItem]
}

@Generable
nonisolated struct GroceryAddition {
    @Guide(description: "A short shopping name")
    var name: String
    var section: GroceryAisle
    @Guide(description: "How many to buy, at least 1")
    var quantity: Int
}

@Generable
nonisolated struct GroceryAdditions {
    var items: [GroceryAddition]
}
