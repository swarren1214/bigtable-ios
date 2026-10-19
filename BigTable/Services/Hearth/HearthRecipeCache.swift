import Foundation

/// Recipes as BigTable shares them with the other Hearth apps (title, servings, ingredients),
/// kept in memory so editing the plan doesn't fetch the same recipe again.
@MainActor
final class HearthRecipeCache {
    static let shared = HearthRecipeCache()

    /// A recipe at one version. A nil `versionID` is whatever version the API serves.
    nonisolated struct Key: Hashable, Sendable {
        var recipeID: String
        var versionID: String?
    }

    /// How many recipes load at once.
    nonisolated private static let maxConcurrent = 4
    /// How long to wait before trying a recipe that failed to load again.
    nonisolated private static let retryAfter: TimeInterval = 10 * 60

    private var recipes: [Key: HearthMealPlan.Recipe] = [:]
    private var failedAt: [Key: Date] = [:]

    func recipe(for key: Key) -> HearthMealPlan.Recipe? {
        recipes[key]
    }

    /// Not loaded yet, and not a recent failure.
    func needsLoad(_ key: Key, now: Date = .now) -> Bool {
        guard recipes[key] == nil else { return false }
        guard let failed = failedAt[key] else { return true }
        return now.timeIntervalSince(failed) > Self.retryAfter
    }

    /// Loads these recipes, a few at a time. Ones that fail are skipped for a while.
    func load(_ keys: [Key]) async {
        guard !keys.isEmpty else { return }
        let limit = Self.maxConcurrent
        let results = await withTaskGroup(of: (Key, RecipeDetail?).self, returning: [(Key, RecipeDetail?)].self) { group in
            var remaining = keys.makeIterator()
            for _ in 0..<limit {
                guard let key = remaining.next() else { break }
                group.addTask { await Self.fetch(key) }
            }
            var loaded: [(Key, RecipeDetail?)] = []
            while let result = await group.next() {
                loaded.append(result)
                if let key = remaining.next() {
                    group.addTask { await Self.fetch(key) }
                }
            }
            return loaded
        }
        guard !Task.isCancelled else { return }
        let now = Date.now
        for (key, detail) in results {
            if let detail {
                recipes[key] = Self.hearthRecipe(from: detail, id: key.recipeID)
                failedAt[key] = nil
            } else {
                failedAt[key] = now
            }
        }
    }

    /// Signed out: forget this account's recipes.
    func removeAll() {
        recipes = [:]
        failedAt = [:]
    }

    nonisolated private static func fetch(_ key: Key) async -> (Key, RecipeDetail?) {
        let detail = try? await KitchenStore.shared.recipe(key.recipeID, versionId: key.versionID)
        return (key, detail)
    }

    private static func hearthRecipe(from detail: RecipeDetail, id: String) -> HearthMealPlan.Recipe {
        let ingredients = detail.ingredients.compactMap { ingredient -> HearthMealPlan.Ingredient? in
            let name = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return HearthMealPlan.Ingredient(name: name, amount: ingredient.amount, unit: unit(ingredient.measurementType))
        }
        return HearthMealPlan.Recipe(
            id: id,
            title: detail.title,
            servings: detail.baseServings > 0 ? detail.baseServings : nil,
            ingredients: ingredients
        )
    }

    /// The stored measurement, or nil for none ("", "none", "—").
    private static func unit(_ measurementType: String?) -> String? {
        let value = (measurementType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let none: Set<String> = ["", "none", "-", "—", "null", "n/a"]
        return none.contains(value.lowercased()) ? nil : value
    }
}
