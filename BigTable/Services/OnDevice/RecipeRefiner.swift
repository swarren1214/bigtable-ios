import Foundation
import FoundationModels
import OSLog

/// Changes a recipe the way the cook asks ("make it dairy-free and enough for 12", "can it go
/// in the slow cooker?") with Apple's on-device model, and says what it changed. Nothing
/// leaves the phone. Returns nil when the model isn't available here or couldn't do it; the
/// editor then asks the API instead.
nonisolated enum RecipeRefiner {
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "RecipeRefiner")

    /// The on-device model's context is small: the recipe, the instructions and the answer all
    /// have to fit, so very long recipes go to the API.
    static let maxRecipeCharacters = 4_500

    nonisolated struct Output: Sendable {
        var title: String
        var summary: String
        var servings: Int
        var prepMinutes: Int
        var cookMinutes: Int
        var difficulty: String
        var tags: [String]
        var ingredients: [String]
        var steps: [String]
        var reply: String
    }

    /// - Parameters:
    ///   - recipe: the recipe as text (see `RecipeEditorModel.recipeText`), or empty when
    ///     there's nothing written yet.
    ///   - request: what the cook asked for.
    static func refine(recipe: String, request: String) async -> Output? {
        guard OnDeviceRecipeParser.isAvailable, recipe.count <= maxRecipeCharacters, request.count <= 600 else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let prompt = recipe.isEmpty
            ? "There's no recipe yet. Write a complete one from this: \(request)"
            : "The recipe:\n\(recipe)\n\nThe change: \(request)"
        do {
            let response = try await session.respond(
                to: prompt,
                generating: RefinedRecipe.self,
                options: GenerationOptions(temperature: 0.3)
            )
            let result = response.content
            let ingredients = clean(result.ingredients)
            let steps = clean(result.steps)
            guard !ingredients.isEmpty, !steps.isEmpty else { return nil }
            let reply = result.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return Output(
                title: String(result.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),
                summary: String(result.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(450)),
                servings: result.servings,
                prepMinutes: result.prepMinutes,
                cookMinutes: result.cookMinutes,
                difficulty: result.difficulty.lowercased(),
                tags: result.tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty },
                ingredients: ingredients,
                steps: steps,
                reply: reply.isEmpty ? "Done. Here's the updated recipe." : String(reply.prefix(400))
            )
        } catch {
            log.notice("On-device recipe change fell back to the API: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static let instructions = """
        You help a busy parent change a family recipe in a meal-planning app.
        Apply the change they ask for and return the whole updated recipe.
        Keep everything they didn't ask to change exactly as it was: the same wording, amounts and order.
        When the number of servings changes, scale every ingredient amount to match.
        When an ingredient is swapped, update the steps that mention it.
        Ingredient lines have the amount first, like "2 cups beef broth" or "4 cloves garlic, minced".
        Steps are in order, one action each, without numbers.
        prepMinutes and cookMinutes are whole minutes, 0 when unknown.
        Keep the recipe's tags, adding or removing one only when the change calls for it, such as "dairy-free".
        The reply is one or two short, friendly sentences telling them what you changed. No greeting.
        If the request has nothing to do with the recipe, return the recipe unchanged and say in the reply what kinds of changes you can make.
        """

    private static func clean(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(80).map { $0 }
    }
}

/// The updated recipe the on-device model writes, then its reply (written last, so it
/// describes what it actually did).
@Generable
nonisolated struct RefinedRecipe {
    @Guide(description: "The recipe's name")
    var title: String
    @Guide(description: "One or two short sentences about the dish")
    var summary: String
    @Guide(description: "How many people it serves", .range(1...50))
    var servings: Int
    @Guide(description: "Hands-on prep time in minutes, 0 when unknown", .range(0...600))
    var prepMinutes: Int
    @Guide(description: "Cooking time in minutes, 0 when unknown", .range(0...1_440))
    var cookMinutes: Int
    @Guide(description: "How hard it is to make", .anyOf(["easy", "medium", "hard"]))
    var difficulty: String
    @Guide(description: "Lowercase tags, like dinner, italian or dairy-free")
    var tags: [String]
    @Guide(description: "Every ingredient line with its amount, in order")
    var ingredients: [String]
    @Guide(description: "Every step in order, without numbers")
    var steps: [String]
    @Guide(description: "One or two short sentences telling the cook what changed")
    var reply: String
}
