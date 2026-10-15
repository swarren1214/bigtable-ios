import Foundation
import FoundationModels
import OSLog

/// Plan My Week on the device. The API's planner sent up to 210 recipe titles to Claude; the
/// on-device model has far less room, so plain code narrows the household's recipes first
/// (restrictions, the recipe mix, meal type, quick tags, likes and dislikes) to a short list
/// per meal, and the model places them, reading the prompt. A port of lib/ai-meal-plan.ts.
///
/// It returns the plan in the API's shape (`generatedPlan`), which the app sends back to the
/// API to preview and save, so the API builds the preview and stores the plan exactly as
/// before, without calling Claude. Nil means the API plans it instead.
enum OnDeviceMealPlanner {
    nonisolated private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "OnDevicePlanner")
    typealias Plan = [String: [String: String]]

    enum Bucket: String, CaseIterable {
        case mine, favorites, other
        var label: String {
            switch self {
            case .mine: "My Recipes"
            case .favorites: "Favorites"
            case .other: "Other Recipes"
            }
        }
    }

    struct Candidate: Hashable {
        var title: String
        var tags: [String]
        var minutes: Int?
        var bucket: Bucket
        var haystack: String { (title + " " + tags.joined(separator: " ")).lowercased() }
    }

    struct Cell: Hashable {
        var day: DayOfWeek
        var slot: MealSlotType
    }

    /// The organizer's Pro plan, on a phone with Apple Intelligence. Members' plans use the
    /// organizer's recipes, which the API knows best, so they go to the API.
    static var canPlan: Bool {
        OnDeviceRecipeParser.isAvailable && AppModel.shared.usage?.tier == "pro" && AppModel.shared.isOrganizer
    }

    static func plan(for request: MealPlanRequest) async -> (plan: Plan, cells: Int)? {
        guard canPlan else { return nil }
        let cells = selectedCells(request.selectedMeals ?? [:])
        guard !cells.isEmpty else { return nil }
        guard let buckets = try? await loadBuckets(), buckets.values.contains(where: { !$0.isEmpty }) else { return nil }

        let household = AppModel.shared.me
        let restrictions = household?.dietaryRestrictions.map(\.value) ?? []
        let likes = Array(Set((household?.householdMembers ?? []).flatMap(\.likes).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).prefix(40)
        let dislikes = Array(Set((household?.householdMembers ?? []).flatMap(\.dislikes).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).prefix(40)

        // Restrictions are hard rules; drop recipes that mention a blocked food.
        let blocked = blockedKeywords(restrictions)
        var allowed = buckets.mapValues { $0.filter { recipe in !blocked.contains { recipe.haystack.contains($0) } } }
        if allowed.values.allSatisfy(\.isEmpty) { allowed = buckets }

        let targets = apportion(cells.count, mix: request.recipeMix ?? RecipeMix(mine: 50, favorites: 25, other: 25), nonEmpty: allowed.mapValues { !$0.isEmpty })
        let shortlist = makeShortlist(allowed, cells: cells, targets: targets, quickTags: Set(request.quickTags), dislikes: Array(dislikes), seed: request.prompt)
        guard !shortlist.isEmpty else { return nil }

        guard let picks = await place(cells: cells, shortlist: shortlist, targets: targets, request: request, likes: Array(likes), dislikes: Array(dislikes), restrictions: restrictions) else { return nil }
        return (fullWeek(picks, filler: shortlist[0].title), cells.count)
    }

    // MARK: Recipes

    /// The three recipe pools of the API's recipe mix: the household's own recipes, favorites
    /// that aren't theirs, and published recipes that are neither.
    private static func loadBuckets() async throws -> [Bucket: [Candidate]] {
        let api = BigTableAPI.shared
        async let mineFirst = api.recipes(collection: "my", limit: 50, offset: 0)
        async let mineNext = api.recipes(collection: "my", limit: 50, offset: 50)
        async let favorites = api.favoriteRecipes()
        async let allFirst = api.recipes(limit: 50, offset: 0)
        async let allNext = api.recipes(limit: 50, offset: 50)
        let mine = try await mineFirst.recipes + ((try? await mineNext.recipes) ?? [])
        let favoriteList = try await favorites.recipes
        let everyone = try await allFirst.recipes + ((try? await allNext.recipes) ?? [])

        var seen = Set<String>()
        func candidates(_ recipes: [RecipeSummary], _ bucket: Bucket) -> [Candidate] {
            recipes.compactMap { recipe in
                let title = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, recipe.status != .removed, seen.insert(title.lowercased()).inserted else { return nil }
                let minutes = [recipe.prepMinutes, recipe.cookMinutes].compactMap { $0 }
                return Candidate(title: title, tags: recipe.tags, minutes: minutes.isEmpty ? nil : minutes.reduce(0, +), bucket: bucket)
            }
        }
        let mineIDs = Set(mine.map(\.id))
        let favoriteIDs = Set(favoriteList.map(\.id))
        return [
            .mine: Array(candidates(mine, .mine).prefix(110)),
            .favorites: Array(candidates(favoriteList.filter { !mineIDs.contains($0.id) && ($0.status ?? .published) == .published }, .favorites).prefix(110)),
            .other: Array(candidates(everyone.filter { !mineIDs.contains($0.id) && !favoriteIDs.contains($0.id) && $0.status == .published }, .other).prefix(110)),
        ]
    }

    // MARK: Narrowing

    private static func selectedCells(_ selectedMeals: [String: [String]]) -> [Cell] {
        // Monday first, as the API's planner orders the week.
        let week: [DayOfWeek] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        return week.flatMap { day in
            MealSlotType.allCases.compactMap { slot in
                (selectedMeals[day.rawValue] ?? []).contains(slot.rawValue) ? Cell(day: day, slot: slot) : nil
            }
        }
    }

    private static let slotKeywords: [MealSlotType: [String]] = [
        .breakfast: ["breakfast", "pancake", "waffle", "omelet", "oat", "toast", "muffin", "egg", "smoothie", "granola", "frittata"],
        .lunch: ["lunch", "sandwich", "wrap", "salad", "soup", "bowl", "quesadilla", "burger"],
        .dinner: ["dinner", "pasta", "roast", "stew", "curry", "skillet", "casserole", "enchilada", "chili", "tacos", "lasagna"],
    ]

    /// Recipes that look right for a meal; recipes that match no meal fit any.
    private static func pool(_ recipes: [Candidate], for slot: MealSlotType) -> [Candidate] {
        recipes.filter { recipe in
            let text = recipe.haystack
            let matches = MealSlotType.allCases.filter { type in
                (slotKeywords[type] ?? []).contains { keyword in text.contains(keyword) }
            }
            return matches.isEmpty || matches.contains(slot)
        }
    }

    private static let restrictionKeywords: [(String, [String])] = [
        ("fish", ["fish", "salmon", "tuna", "cod", "tilapia", "sardine", "anchovy", "trout"]),
        ("seafood", ["shrimp", "prawn", "crab", "lobster", "mussel", "clam", "oyster", "scallop"]),
        ("shellfish", ["shrimp", "prawn", "crab", "lobster", "mussel", "clam", "oyster", "scallop"]),
        ("dairy", ["milk", "cream", "butter", "cheese", "yogurt"]),
        ("gluten", ["wheat", "bread", "pasta", "flour", "barley", "rye"]),
        ("nut", ["almond", "cashew", "peanut", "walnut", "pecan", "hazelnut", "pistachio"]),
        ("egg", ["egg", "eggs"]),
        ("soy", ["soy", "tofu", "edamame", "miso"]),
        ("pork", ["pork", "bacon", "ham", "sausage"]),
        ("beef", ["beef", "steak"]),
        ("chicken", ["chicken"]),
        ("turkey", ["turkey"]),
    ]

    private static func blockedKeywords(_ restrictions: [String]) -> Set<String> {
        let text = restrictions.joined(separator: " ").lowercased()
        return Set(restrictionKeywords.filter { text.contains($0.0) }.flatMap(\.1))
    }

    /// Splits the meals across the pools by the recipe mix (largest remainder), skipping
    /// empty pools, as the API's apportionRecipeSlots does.
    static func apportion(_ total: Int, mix: RecipeMix, nonEmpty: [Bucket: Bool]) -> [Bucket: Int] {
        var counts: [Bucket: Int] = [.mine: 0, .favorites: 0, .other: 0]
        let available = Bucket.allCases.filter { nonEmpty[$0] == true }
        guard total > 0, !available.isEmpty else { return counts }
        let weights: [Bucket: Int] = [.mine: max(mix.mine, 0), .favorites: max(mix.favorites, 0), .other: max(mix.other, 0)]
        let weightSum = available.reduce(0) { $0 + weights[$1]! }
        func weight(_ bucket: Bucket) -> Double { weightSum > 0 ? Double(weights[bucket]!) : 1 }
        let sum = weightSum > 0 ? Double(weightSum) : Double(available.count)
        var remainders: [(Bucket, Double)] = []
        for bucket in available {
            let exact = Double(total) * weight(bucket) / sum
            counts[bucket] = Int(exact.rounded(.down))
            remainders.append((bucket, exact - exact.rounded(.down)))
        }
        var left = total - counts.values.reduce(0, +)
        let order = remainders.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if weight(lhs.0) != weight(rhs.0) { return weight(lhs.0) > weight(rhs.0) }
            return Bucket.allCases.firstIndex(of: lhs.0)! < Bucket.allCases.firstIndex(of: rhs.0)!
        }
        var index = 0
        while left > 0, !order.isEmpty {
            counts[order[index % order.count].0, default: 0] += 1
            left -= 1
            index += 1
        }
        return counts
    }

    /// A short list for the model: for each meal type, about three recipes per meal to fill,
    /// drawn from the pools in the mix's proportions, leaning toward quick recipes when the
    /// week is busy and away from dislikes. At most 48 in all, to fit the model.
    private static func makeShortlist(_ buckets: [Bucket: [Candidate]], cells: [Cell], targets: [Bucket: Int], quickTags: Set<String>, dislikes: [String], seed: String) -> [Candidate] {
        let wantsQuick = quickTags.contains("under_30") || quickTags.contains("busy_weekdays")
        let dislikeWords = dislikes.map { $0.lowercased() }
        var generator = SeededGenerator(seed: seed + cells.map { "\($0.day.rawValue)\($0.slot.rawValue)" }.joined())
        let totalTarget = max(targets.values.reduce(0, +), 1)
        var chosen: [Candidate] = []
        var taken = Set<String>()

        // Share the 48 places among the meal types being planned, so dinners aren't crowded
        // out by breakfasts and lunches.
        let slotCount = max(Set(cells.map(\.slot)).count, 1)
        for slot in MealSlotType.allCases {
            let meals = cells.filter { $0.slot == slot }.count
            guard meals > 0 else { continue }
            let wanted = min(max(meals * 3, 6), 48 / slotCount)
            var picked = 0
            for bucket in Bucket.allCases {
                let share = Int((Double(wanted) * Double(targets[bucket] ?? 0) / Double(totalTarget)).rounded(.up))
                guard share > 0 else { continue }
                let ranked = pool(buckets[bucket] ?? [], for: slot)
                    .filter { !taken.contains($0.title.lowercased()) }
                    .shuffled(using: &generator)
                    .sorted { score($0, quick: wantsQuick, dislikes: dislikeWords) > score($1, quick: wantsQuick, dislikes: dislikeWords) }
                for recipe in ranked.prefix(min(share, wanted - picked)) {
                    taken.insert(recipe.title.lowercased())
                    chosen.append(recipe)
                    picked += 1
                }
            }
            // Top up from any pool when the mix's pools run short.
            let have = picked
            if have < meals {
                let extra = Bucket.allCases.flatMap { pool(buckets[$0] ?? [], for: slot) }
                    .filter { !taken.contains($0.title.lowercased()) }
                    .shuffled(using: &generator)
                for recipe in extra.prefix(meals - have) {
                    taken.insert(recipe.title.lowercased())
                    chosen.append(recipe)
                }
            }
        }
        return Array(chosen.prefix(48))
    }

    private static func score(_ recipe: Candidate, quick: Bool, dislikes: [String]) -> Int {
        var score = 0
        if dislikes.contains(where: { !$0.isEmpty && recipe.haystack.contains($0) }) { score -= 3 }
        if quick, let minutes = recipe.minutes { score += minutes <= 30 ? 2 : (minutes > 60 ? -1 : 0) }
        return score
    }

    // MARK: Placing

    private static func place(cells: [Cell], shortlist: [Candidate], targets: [Bucket: Int], request: MealPlanRequest, likes: [String], dislikes: [String], restrictions: [String]) async -> [Cell: String]? {
        let recipeLines = shortlist.enumerated().map { index, recipe in
            var line = "R\(index + 1). \(recipe.title)"
            if let minutes = recipe.minutes { line += " (\(minutes) min)" }
            if !recipe.tags.isEmpty { line += " [\(recipe.tags.prefix(3).joined(separator: ", "))]" }
            return line + " {\(recipe.bucket.label)}"
        }
        let mealLines = cells.enumerated().map { index, cell in "M\(index + 1). \(cell.day.rawValue.capitalized) \(cell.slot.rawValue)" }
        let tagText = request.quickTags.compactMap { tag in AIPlanQuickTag.all.first { $0.id == tag }?.label }.joined(separator: ", ")
        let mixText = Bucket.allCases.compactMap { bucket in (targets[bucket] ?? 0) > 0 ? "about \(targets[bucket]!) from {\(bucket.label)}" : nil }.joined(separator: ", ")

        var instructions = [
            "You plan a week of family meals by choosing from a list of the family's recipes.",
            "For every meal (M1, M2, …) choose one recipe number (R1, R2, …) from the list. Never invent recipes.",
            "Use a different recipe for every meal when there are enough; repeat only when you must.",
            "Pick recipes that suit the meal: breakfast foods for breakfast, lighter meals for lunch, heartier ones for dinner.",
            "Faster meals on busy weekdays; bigger meals on weekends.",
            "Style: \(request.mealStyle.label).",
        ]
        if !mixText.isEmpty { instructions.append("Recipe sources: aim for \(mixText). It's a preference, not a rule.") }
        if !tagText.isEmpty { instructions.append("This week: \(tagText).") }
        if !likes.isEmpty { instructions.append("The family likes: \(likes.joined(separator: ", ")).") }
        if !dislikes.isEmpty { instructions.append("Avoid when you can: \(dislikes.joined(separator: ", ")).") }
        if !restrictions.isEmpty { instructions.append("Dietary restrictions: \(restrictions.joined(separator: ", ")).") }

        var prompt = ""
        if !request.prompt.isEmpty { prompt += "What the family asked for: \(request.prompt)\n\n" }
        prompt += "Meals to plan:\n\(mealLines.joined(separator: "\n"))\n\nRecipes:\n\(recipeLines.joined(separator: "\n"))"

        let session = LanguageModelSession(instructions: instructions.joined(separator: "\n"))
        let picks: [MealPick]
        do {
            let response = try await session.respond(to: prompt, generating: MealPlanPicks.self, options: GenerationOptions(temperature: 0.6))
            picks = response.content.meals
        } catch {
            log.notice("On-device planning fell back to the API: \(String(describing: error), privacy: .public)")
            return nil
        }

        // Keep valid picks, avoid repeats where another recipe fits, and fill what's missing.
        var placed: [Cell: String] = [:]
        var used = Set<String>()
        for pick in picks {
            guard (1...cells.count).contains(pick.meal), (1...shortlist.count).contains(pick.recipe) else { continue }
            let cell = cells[pick.meal - 1]
            guard placed[cell] == nil else { continue }
            let recipe = shortlist[pick.recipe - 1]
            placed[cell] = recipe.title
            used.insert(recipe.title.lowercased())
        }
        // A plan where the model skipped most meals isn't the model's plan; let the API do it.
        guard placed.count * 2 >= cells.count else { return nil }
        for cell in cells where placed[cell] == nil {
            let fits = pool(shortlist, for: cell.slot)
            let pick = fits.first { !used.contains($0.title.lowercased()) } ?? fits.first ?? shortlist[0]
            placed[cell] = pick.title
            used.insert(pick.title.lowercased())
        }
        return placed
    }

    /// The API wants every day and meal filled; meals that weren't asked for are ignored.
    private static func fullWeek(_ placed: [Cell: String], filler: String) -> Plan {
        var plan: Plan = [:]
        for day in DayOfWeek.allCases {
            var meals: [String: String] = [:]
            for slot in MealSlotType.allCases {
                meals[slot.rawValue] = placed[Cell(day: day, slot: slot)] ?? filler
            }
            plan[day.rawValue] = meals
        }
        return plan
    }
}

/// A repeatable shuffle, so the same request draws the same short list.
nonisolated private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: String) {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        state = hash == 0 ? 0x9E3779B97F4A7C15 : hash
    }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

@Generable
nonisolated struct MealPick {
    @Guide(description: "The meal's number, from M1, M2, … (just the number)")
    var meal: Int
    @Guide(description: "The chosen recipe's number, from R1, R2, … (just the number)")
    var recipe: Int
}

@Generable
nonisolated struct MealPlanPicks {
    @Guide(description: "One pick for every meal to plan")
    var meals: [MealPick]
}
