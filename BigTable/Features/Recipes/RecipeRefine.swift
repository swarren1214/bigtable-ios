import Foundation

/// The recipe's content at one moment, kept so a change made by talking to AI can be undone
/// and shown (what's new, changed or removed).
nonisolated struct RecipeDraft: Sendable {
    var title = ""
    var details = ""
    var servings = 8
    var prepText = ""
    var cookText = ""
    var difficulty = ""
    var tags: [String] = []
    var ingredients: [RecipeIngredientDraft] = []
    var steps: [RecipeStepDraft] = []

    var hasContent: Bool {
        !title.recipeTrimmed.isEmpty || !ingredients.isEmpty || !steps.isEmpty
    }
}

/// One change asked for by talking or typing: what was asked, AI's reply, and the recipe from
/// before it (for Undo and the change badges).
nonisolated struct RecipeRefineTurn: Identifiable, Sendable {
    var id = UUID()
    var request: String
    var reply: String
    var before: RecipeDraft
}

/// How an ingredient compares with the recipe before the last change.
nonisolated enum RecipeChangeKind: Sendable {
    case same, new, changed, removed
}

/// An ingredient row on the refine screen.
nonisolated struct RecipeIngredientChange: Identifiable, Sendable {
    var id: String
    var amount: String
    var name: String
    var kind: RecipeChangeKind
    /// The old amount, when only the amount changed.
    var was: String?
}

extension RecipeEditorModel {
    /// What's in the form now (blank rows left out).
    var draft: RecipeDraft {
        RecipeDraft(
            title: title,
            details: details,
            servings: servings,
            prepText: prepText,
            cookText: cookText,
            difficulty: difficulty,
            tags: tags,
            ingredients: ingredients.filter { !$0.isBlank },
            steps: steps.filter { !$0.text.recipeTrimmed.isEmpty }
        )
    }

    func restore(_ draft: RecipeDraft) {
        title = draft.title
        details = draft.details
        servings = draft.servings
        prepText = draft.prepText
        cookText = draft.cookText
        difficulty = draft.difficulty
        tags = draft.tags
        ingredients = draft.ingredients
        steps = draft.steps
    }

    /// The recipe before the last change, to compare with.
    var refineBaseline: RecipeDraft? { refineTurns.last?.before }

    /// Changes the recipe the way the cook asked, with Apple's on-device model when this phone
    /// has Apple Intelligence and the API otherwise. Returns AI's reply.
    @discardableResult
    func refine(_ request: String) async throws -> String {
        let ask = request.recipeTrimmed
        guard !ask.isEmpty, !isRefining else { return "" }
        isRefining = true
        defer { isRefining = false }

        let before = draft
        let text = before.hasContent ? Self.recipeText(before) : ""
        let reply: String
        if let output = await RecipeRefiner.refine(recipe: text, request: ask) {
            applyRefined(output)
            reply = output.reply
        } else {
            let prompt = text.isEmpty ? ask : "Here is a recipe:\n\(text)\n\nWrite out the whole recipe again with this change: \(ask)"
            let response = try await BigTableAPI.shared.recipeFromTranscript(String(prompt.prefix(12_000)))
            switch apply(response, notRecipeFallback: "AI couldn't make that change. Try saying it another way.") {
            case .filled:
                reply = "Done. Here's the updated recipe."
            case .notRecipe(let reason):
                throw RecipeEditorError(message: reason)
            case .nothingFound:
                throw RecipeEditorError(message: "AI couldn't make that change. Try saying it another way.")
            }
        }
        madeWithAI = true
        refineTurns.append(RecipeRefineTurn(request: ask, reply: reply, before: before))
        generatePhotoIfMissing()
        return reply
    }

    /// Puts the recipe back the way it was before the last change.
    func undoRefine() {
        guard let last = refineTurns.popLast() else { return }
        restore(last.before)
    }

    private func applyRefined(_ output: RecipeRefiner.Output) {
        if !output.title.isEmpty { title = output.title }
        if !output.summary.isEmpty { details = output.summary }
        if Self.servingsRange.contains(output.servings) { servings = output.servings }
        if output.prepMinutes > 0 { prepText = String(output.prepMinutes) }
        if output.cookMinutes > 0 { cookText = String(output.cookMinutes) }
        if Self.difficulties.contains(output.difficulty) { difficulty = output.difficulty }
        let newTags = Self.unique(output.tags)
        if !newTags.isEmpty { tags = Array(newTags.prefix(10)) }

        // Rows that didn't change keep their identity, so the list doesn't redraw them.
        var oldRows = Dictionary(ingredients.map { (Self.ingredientLine($0), $0) }, uniquingKeysWith: { first, _ in first })
        let rows = output.ingredients
            .map { Ingredients.parseLine(Self.stripBullet($0)) }
            .filter { !$0.name.recipeTrimmed.isEmpty }
            .map { input -> RecipeIngredientDraft in
                let fresh = RecipeIngredientDraft(input)
                return oldRows.removeValue(forKey: Self.ingredientLine(fresh)) ?? fresh
            }
        if !rows.isEmpty { ingredients = rows }

        var oldSteps = Dictionary(steps.map { ($0.text.recipeTrimmed, $0) }, uniquingKeysWith: { first, _ in first })
        let stepRows = output.steps
            .map(RecipeFormat.stripStepNumber)
            .filter { !$0.isEmpty }
            .map { text in oldSteps.removeValue(forKey: text) ?? RecipeStepDraft(text: text) }
        if !stepRows.isEmpty { steps = stepRows }
    }

    // MARK: Text for AI

    /// "2 cups beef broth".
    static func ingredientLine(_ row: RecipeIngredientDraft) -> String {
        let unit = row.measurement.isEmpty ? "" : Ingredients.shortLabel(row.measurement)
        return [row.amount.recipeTrimmed, unit, row.name.recipeTrimmed].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The recipe written out for the model to change.
    static func recipeText(_ draft: RecipeDraft) -> String {
        var lines: [String] = []
        if !draft.title.recipeTrimmed.isEmpty { lines.append("Title: \(draft.title.recipeTrimmed)") }
        if !draft.details.recipeTrimmed.isEmpty { lines.append("About: \(draft.details.recipeTrimmed)") }
        lines.append("Serves: \(draft.servings)")
        if let prep = Int(draft.prepText), prep > 0 { lines.append("Prep: \(prep) minutes") }
        if let cook = Int(draft.cookText), cook > 0 { lines.append("Cook: \(cook) minutes") }
        if !draft.difficulty.isEmpty { lines.append("Difficulty: \(draft.difficulty)") }
        if !draft.tags.isEmpty { lines.append("Tags: \(draft.tags.joined(separator: ", "))") }
        if !draft.ingredients.isEmpty {
            lines.append("Ingredients:")
            lines.append(contentsOf: draft.ingredients.map { "- \(ingredientLine($0))" })
        }
        if !draft.steps.isEmpty {
            lines.append("Steps:")
            lines.append(contentsOf: draft.steps.enumerated().map { "\($0.offset + 1). \($0.element.text.recipeTrimmed)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Changes

    /// The ingredients compared with the recipe before the last change: new, changed (with the
    /// old amount) and, at the end, removed.
    var ingredientChanges: [RecipeIngredientChange] {
        let current = ingredients.filter { !$0.isBlank }
        guard let before = refineBaseline?.ingredients else {
            return current.map { RecipeIngredientChange(id: $0.id.uuidString, amount: Self.amountText($0), name: $0.name.recipeTrimmed, kind: .same) }
        }
        var previous: [String: RecipeIngredientDraft] = [:]
        for row in before where previous[Self.matchKey(row)] == nil { previous[Self.matchKey(row)] = row }
        var matched = Set<String>()
        var rows: [RecipeIngredientChange] = current.map { row in
            let key = Self.matchKey(row)
            let amount = Self.amountText(row)
            guard let old = previous[key], !matched.contains(key) else {
                return RecipeIngredientChange(id: row.id.uuidString, amount: amount, name: row.name.recipeTrimmed, kind: .new)
            }
            matched.insert(key)
            let oldAmount = Self.amountText(old)
            if oldAmount != amount {
                return RecipeIngredientChange(id: row.id.uuidString, amount: amount, name: row.name.recipeTrimmed, kind: .changed, was: oldAmount.isEmpty ? nil : oldAmount)
            }
            let kind: RecipeChangeKind = old.name.recipeTrimmed == row.name.recipeTrimmed ? .same : .changed
            return RecipeIngredientChange(id: row.id.uuidString, amount: amount, name: row.name.recipeTrimmed, kind: kind)
        }
        for row in before where !matched.contains(Self.matchKey(row)) {
            matched.insert(Self.matchKey(row))
            rows.append(RecipeIngredientChange(id: "removed-\(row.id.uuidString)", amount: Self.amountText(row), name: row.name.recipeTrimmed, kind: .removed))
        }
        return rows
    }

    /// Whether step `index` is new or reworded since the last change.
    func stepChanged(at index: Int) -> Bool {
        guard let before = refineBaseline?.steps else { return false }
        let current = steps.filter { !$0.text.recipeTrimmed.isEmpty }
        guard index < current.count else { return false }
        return index >= before.count || before[index].text.recipeTrimmed != current[index].text.recipeTrimmed
    }

    /// "2 lb", "4 cloves", or "".
    static func amountText(_ row: RecipeIngredientDraft) -> String {
        let unit = row.measurement.isEmpty ? "" : Ingredients.shortLabel(row.measurement)
        return [row.amount.recipeTrimmed, unit].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The ingredient without its preparation ("garlic, minced" matches "garlic").
    private static func matchKey(_ row: RecipeIngredientDraft) -> String {
        let name = row.name.lowercased()
        let core = name.split(separator: ",", maxSplits: 1).first.map(String.init) ?? name
        return core.recipeTrimmed
    }
}
