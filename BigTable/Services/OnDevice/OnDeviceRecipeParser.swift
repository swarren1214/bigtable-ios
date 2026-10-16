import Foundation
import FoundationModels
import OSLog

/// Reads a recipe out of a web page's text or a scan with Apple's on-device model, instead of
/// sending it to the API. (It copies out a recipe that's there; writing one from a short ask
/// goes to the API, since the small model leaves out what wasn't named.) It returns the API's shape
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
        /// A web page's readable text, with menus, ads and comments around the recipe.
        case webPage
        /// Text read from photos of a cookbook page, a recipe card or a screenshot.
        case scan
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
            "prepMinutes and cookMinutes are whole minutes when known or easy to estimate; difficulty is easy, medium or hard.",
            "Tags may only come from this list: \(supportedTags.joined(separator: ", ")).",
        ]
        switch source {
        case .webPage:
            lines.append("The text comes from a recipe web page. Use only the page's main recipe: ignore menus, ads, comments, ratings, nutrition facts and other suggested recipes. Don't invent ingredients or steps that aren't on the page.")
            lines.append("If the page has no recipe, set isRecipe to false and give a short failureReason.")
        case .scan:
            lines.append("The text was read from photos of a cookbook page, a recipe card or a screenshot, so it may have reading mistakes, broken lines, and an ingredient or step repeated where two photos overlap. Use only the main recipe: ignore ads, navigation, suggested recipes, comments, ratings and nutrition facts. Fix obvious reading mistakes, join broken lines, and drop repeats. Don't invent ingredients or steps.")
            lines.append("If there's no recipe, set isRecipe to false and give a short failureReason.")
        }
        return lines.joined(separator: "\n")
    }

    private static func prompt(for source: Source, text: String) -> String {
        switch source {
        case .webPage: "The page's text:\n\(text)"
        case .scan: "The text read from the photos:\n\(text)"
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
            failureReason: isRecipe ? nil : clean(recipe.failureReason, limit: 220),
            prepMinutes: isRecipe ? recipe.prepMinutes.flatMap { (1...1_440).contains($0) ? $0 : nil } : nil,
            cookMinutes: isRecipe ? recipe.cookMinutes.flatMap { (1...1_440).contains($0) ? $0 : nil } : nil,
            difficulty: isRecipe ? recipe.difficulty.map { $0.lowercased() }.flatMap { ["easy", "medium", "hard"].contains($0) ? $0 : nil } : nil
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
    @Guide(description: "Hands-on prep time in minutes, when known")
    var prepMinutes: Int?
    @Guide(description: "Cooking time in minutes, when known")
    var cookMinutes: Int?
    @Guide(description: "easy, medium or hard")
    var difficulty: String?
    @Guide(description: "Why this isn't a recipe, when isRecipe is false")
    var failureReason: String?
}
