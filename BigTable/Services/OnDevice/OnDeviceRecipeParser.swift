import Foundation
import FoundationModels
import OSLog

/// Turns what someone said or typed (or a web page's text) into a recipe with Apple's
/// on-device model, instead of sending it to the API. It returns the API's shape
/// (`GeneratedRecipeResponse`), so the editor fills in the same way either path.
///
/// The model needs Apple Intelligence (iPhone 15 Pro or later, turned on in Settings). When
/// it's not available, or the text is too long for it, callers use the API as before.
nonisolated enum OnDeviceRecipeParser {
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "OnDeviceRecipe")

    /// The on-device model has a small context, so long text goes to the API instead.
    static let maxInputCharacters = 7_000

    /// The recipe tags BigTable uses (the API's SUPPORTED_RECIPE_TAGS).
    static let supportedTags: [String] = [
        "breakfast", "lunch", "dinner", "dessert", "side",
        "beef", "chicken", "seafood", "pork", "lamb",
        "vegetarian", "vegan", "gluten-free", "dairy-free", "kosher", "halal", "high-protein",
        "italian", "mexican", "french", "american", "british", "spanish", "greek",
        "mediterranean", "middle-eastern", "caribbean", "african",
        "indian", "thai", "japanese", "chinese", "vietnamese", "korean", "eastern-european",
    ]

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    enum Source {
        /// A voice note or typed description: describe a recipe, or ask for one.
        case spoken
        /// A web page's readable text, with menus, ads and comments around the recipe.
        case webPage
    }

    /// Nil when the model isn't available or couldn't handle it; then use the API.
    static func parse(_ text: String, from source: Source) async -> GeneratedRecipeResponse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, !trimmed.isEmpty, trimmed.count <= maxInputCharacters else { return nil }
        let session = LanguageModelSession(instructions: instructions(for: source))
        do {
            let response = try await session.respond(
                to: prompt(for: source, text: trimmed),
                generating: OnDeviceRecipe.self,
                options: GenerationOptions(temperature: 0.2)
            )
            return normalized(response.content)
        } catch {
            log.notice("On-device recipe parse fell back to the API: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func instructions(for source: Source) -> String {
        var lines = [
            "You turn cooking notes into a recipe for a family meal-planning app.",
            "Ingredients are short lines with amounts, like \"2 cups flour\" or \"1 lb ground beef\".",
            "Instructions are ordered steps, each one action, without numbers in front.",
            "The summary is one or two short sentences about the dish.",
            "baseServings is a whole number from 1 to 50 when known.",
            "Tags may only come from this list: \(supportedTags.joined(separator: ", ")).",
        ]
        switch source {
        case .spoken:
            lines.append("The person is either describing a recipe or asking for one to be made. Either way, write a complete recipe that fits what they asked for, including any dietary or style requests.")
            lines.append("If it has nothing to do with food or cooking, set isRecipe to false, give a short failureReason, and leave the recipe fields empty.")
        case .webPage:
            lines.append("The text comes from a recipe web page. Use only the page's main recipe: ignore menus, ads, comments, ratings, nutrition facts and other suggested recipes. Don't invent ingredients or steps that aren't on the page.")
            lines.append("If the page has no recipe, set isRecipe to false and give a short failureReason.")
        }
        return lines.joined(separator: "\n")
    }

    private static func prompt(for source: Source, text: String) -> String {
        switch source {
        case .spoken: "What the person said:\n\(text)"
        case .webPage: "The page's text:\n\(text)"
        }
    }

    private static func normalized(_ recipe: OnDeviceRecipe) -> GeneratedRecipeResponse {
        func clean(_ value: String?, limit: Int) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return String(value.prefix(limit))
        }
        func lines(_ values: [String]) -> [String] {
            values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(80).map { $0 }
        }
        let allowed = Set(supportedTags)
        var seen = Set<String>()
        let tags = recipe.tags
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { allowed.contains($0) && seen.insert($0).inserted }
        let servings = recipe.baseServings.flatMap { (1...50).contains($0) ? Double($0) : nil }
        let ingredients = lines(recipe.ingredients)
        let instructions = lines(recipe.instructions)
        let isRecipe = recipe.isRecipe && !(ingredients.isEmpty && instructions.isEmpty)
        return GeneratedRecipeResponse(
            isRecipe: isRecipe,
            title: isRecipe ? clean(recipe.title, limit: 160) : nil,
            description: isRecipe ? clean(recipe.summary, limit: 450) : nil,
            baseServings: isRecipe ? servings : nil,
            tags: isRecipe ? Array(tags.prefix(10)) : [],
            ingredients: isRecipe ? ingredients : [],
            instructions: isRecipe ? instructions : [],
            failureReason: isRecipe ? nil : clean(recipe.failureReason, limit: 220)
        )
    }
}

/// What the on-device model fills in; the same fields the API returns.
@Generable
nonisolated struct OnDeviceRecipe {
    @Guide(description: "True when this is, or asks for, a recipe")
    var isRecipe: Bool
    @Guide(description: "The recipe's name")
    var title: String?
    @Guide(description: "One or two short sentences about the dish")
    var summary: String?
    @Guide(description: "How many people it serves, from 1 to 50")
    var baseServings: Int?
    @Guide(description: "Tags from the allowed list only, lowercase")
    var tags: [String]
    @Guide(description: "Ingredient lines with amounts, in order")
    var ingredients: [String]
    @Guide(description: "Steps in order, without numbers")
    var instructions: [String]
    @Guide(description: "Why this isn't a recipe, when isRecipe is false")
    var failureReason: String?
}
