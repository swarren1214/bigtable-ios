import Foundation
import Observation

/// Writing a new recipe, or changing one of yours.
enum RecipeEditorMode {
    case create
    case edit(RecipeDetail)
}

/// One ingredient line being typed: an amount ("1 1/2"), a measurement from the picker, and a
/// name.
nonisolated struct RecipeIngredientDraft: Identifiable, Hashable, Sendable {
    var id = UUID()
    var amount = ""
    var measurement = ""
    var name = ""

    init(amount: String = "", measurement: String = "", name: String = "") {
        self.amount = amount
        self.measurement = measurement
        self.name = name
    }

    init(_ input: RecipeIngredientInput) {
        self.amount = input.amount.map { Ingredients.formatAmount($0) } ?? ""
        self.measurement = input.measurementType ?? ""
        self.name = input.name
    }

    var isBlank: Bool {
        amount.recipeTrimmed.isEmpty && measurement.isEmpty && name.recipeTrimmed.isEmpty
    }

    /// Empty, a decimal (1.5), a fraction (1/2) or a mixed fraction (1 1/2).
    var amountIsValid: Bool {
        let text = amount.recipeTrimmed
        return text.isEmpty || Ingredients.parseAmount(text) != nil
    }

    /// What the API stores, or nil while the row has no name.
    var input: RecipeIngredientInput? {
        let trimmedName = name.recipeTrimmed
        guard !trimmedName.isEmpty else { return nil }
        return RecipeIngredientInput(
            amount: Ingredients.parseAmount(amount),
            measurementType: measurement.isEmpty ? nil : measurement,
            name: trimmedName
        )
    }
}

/// One step being typed.
nonisolated struct RecipeStepDraft: Identifiable, Hashable, Sendable {
    var id = UUID()
    var text = ""
}

/// What came of reading a recipe from a recording, a description, a link or a scan.
enum RecipeImportOutcome {
    /// These fields were filled in.
    case filled([String])
    /// It wasn't a recipe; the reason to show.
    case notRecipe(String)
    /// It was read, but nothing usable came back.
    case nothingFound
}

/// A message the editor shows: a title, the details, and whether it should offer Pro.
nonisolated struct RecipeEditorNotice: Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var offersUpgrade = false

    /// An AI or upload failure, offering Pro when the free allowance ran out.
    static func failure(_ error: Error, title: String) -> RecipeEditorNotice {
        if let api = error as? APIError, api.isLimitReached || api.isForbidden {
            return RecipeEditorNotice(title: "BigTable Pro", message: api.localizedDescription, offersUpgrade: true)
        }
        return RecipeEditorNotice(title: title, message: error.localizedDescription)
    }
}

nonisolated struct RecipeEditorError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The recipe form's state and work: the fields, the photo (picked, taken or generated, and
/// uploaded when you save), tags, ingredients and steps, and filling it all in from AI.
/// Mirrors the Expo app's Create Recipe: a title, servings, at least one ingredient and one
/// step, and a photo are required.
@MainActor
@Observable
final class RecipeEditorModel {
    let mode: RecipeEditorMode

    var title = ""
    var details = ""
    var servings = 8
    var prepText = ""
    var cookText = ""
    /// "", "easy", "medium" or "hard".
    var difficulty = ""
    /// Selected tags, lowercased, in the order they were picked.
    var tags: [String] = []
    var ingredients: [RecipeIngredientDraft] = []
    var steps: [RecipeStepDraft] = []

    /// The saved photo's URL (editing, or after an upload).
    var imageURL: String?
    /// A new photo not uploaded yet.
    var photoData: Data?
    var photoMimeType = "image/jpeg"
    /// The photo came from Generate with AI (so it can be regenerated).
    var photoIsAI = false

    private(set) var isSaving = false
    private(set) var isGeneratingImage = false
    private(set) var isScanning = false
    private(set) var isImportingLink = false
    private(set) var isCreatingWithAI = false
    /// Talking to AI to change the recipe (see RecipeRefine.swift).
    var isRefining = false
    /// Each change asked for by talking, oldest first, with the recipe from before it.
    var refineTurns: [RecipeRefineTurn] = []
    /// AI wrote or read in this recipe (from a description, a link or a scan).
    var madeWithAI = false
    /// Shown for a few seconds when Generate with AI is tapped too early.
    private(set) var showsImageHint = false

    @ObservationIgnored private var initial: Snapshot
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    private let api = BigTableAPI.shared

    static let difficulties = ["easy", "medium", "hard"]
    static let servingsRange = 1...50

    init(mode: RecipeEditorMode) {
        self.mode = mode
        initial = Snapshot()
        if case .edit(let recipe) = mode {
            title = recipe.title
            details = recipe.description ?? ""
            servings = min(50, max(1, Int(recipe.baseServings.rounded())))
            prepText = recipe.prepMinutes.map { String($0) } ?? ""
            cookText = recipe.cookMinutes.map { String($0) } ?? ""
            let level = recipe.difficulty?.recipeTrimmed.lowercased() ?? ""
            difficulty = Self.difficulties.contains(level) ? level : ""
            tags = Self.unique(recipe.tags.map { $0.recipeTrimmed.lowercased() })
            let rows = recipe.ingredients.map { RecipeIngredientDraft($0.input) }
            ingredients = rows
            let stepRows = recipe.instructions.map(RecipeFormat.stripStepNumber).filter { !$0.isEmpty }.map { RecipeStepDraft(text: $0) }
            steps = stepRows
            imageURL = recipe.imageUrl
        }
        initial = snapshot()
    }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    // MARK: State

    var hasPhoto: Bool {
        photoData != nil || !(imageURL?.recipeTrimmed.isEmpty ?? true)
    }

    var validIngredients: [RecipeIngredientInput] { ingredients.compactMap(\.input) }
    var validSteps: [String] { steps.map { $0.text.recipeTrimmed }.filter { !$0.isEmpty } }
    var hasInvalidAmount: Bool { ingredients.contains { !$0.amountIsValid } }
    var isBusy: Bool { isSaving || isGeneratingImage || isScanning || isImportingLink || isCreatingWithAI || isRefining }

    var canGenerateImage: Bool {
        !title.recipeTrimmed.isEmpty && !validIngredients.isEmpty && !validSteps.isEmpty
    }

    var canSave: Bool {
        !title.recipeTrimmed.isEmpty
            && Self.servingsRange.contains(servings)
            && !validIngredients.isEmpty
            && !validSteps.isEmpty
            && hasPhoto
            && !hasInvalidAmount
            && !isBusy
    }

    /// What's still missing before Save works, in words.
    var missingForSave: [String] {
        var missing: [String] = []
        if title.recipeTrimmed.isEmpty { missing.append("a title") }
        if validIngredients.isEmpty { missing.append("an ingredient") }
        if validSteps.isEmpty { missing.append("a step") }
        if !hasPhoto { missing.append("a photo") }
        return missing
    }

    var hasChanges: Bool { snapshot() != initial }

    nonisolated private struct Snapshot: Equatable {
        var title = ""
        var details = ""
        var servings = 8
        var prep = ""
        var cook = ""
        var difficulty = ""
        var tags: [String] = []
        var ingredients: [String] = []
        var steps: [String] = []
        var imageURL: String?
        var photoSize = 0
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            title: title.recipeTrimmed,
            details: details.recipeTrimmed,
            servings: servings,
            prep: prepText.recipeTrimmed,
            cook: cookText.recipeTrimmed,
            difficulty: difficulty,
            tags: tags,
            ingredients: ingredients.filter { !$0.isBlank }.map { "\($0.amount.recipeTrimmed)|\($0.measurement)|\($0.name.recipeTrimmed)" },
            steps: validSteps,
            imageURL: imageURL,
            photoSize: photoData?.count ?? 0
        )
    }

    // MARK: Tags

    func isTagSelected(_ normalized: String) -> Bool {
        tags.contains(normalized)
    }

    func toggleTag(_ value: String) {
        let normalized = value.recipeTrimmed.lowercased()
        guard !normalized.isEmpty else { return }
        if let index = tags.firstIndex(of: normalized) {
            tags.remove(at: index)
        } else {
            tags.append(normalized)
        }
    }

    private func selectTag(_ normalized: String) {
        if !tags.contains(normalized) { tags.append(normalized) }
    }

    /// Tags renamed in Manage Tags while this recipe was open follow their new name.
    func applyTagRenames() {
        let renames = RecipeLibrary.shared.renamedTags
        guard !renames.isEmpty else { return }
        tags = Self.unique(tags.map { renames[$0] ?? $0 })
    }

    /// Creates a custom tag and selects it. A name that's already a preset or one of your
    /// tags is selected instead, with a note saying so (as in the Expo app).
    func addCustomTag(_ label: String) async -> RecipeEditorNotice? {
        let cleaned = label.recipeTrimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let trimmed = String(cleaned.prefix(30))
        let normalized = trimmed.lowercased()
        guard !normalized.isEmpty else { return nil }
        if let preset = RecipeQuickFilters.presetLabel(for: normalized) {
            selectTag(normalized)
            return RecipeEditorNotice(title: "Tag already exists", message: "“\(preset)” is already a built-in tag, so it's selected for this recipe.")
        }
        if let existing = RecipeLibrary.shared.customTags.first(where: { $0.normalized == normalized }) {
            selectTag(existing.normalized)
            return RecipeEditorNotice(title: "Tag already exists", message: "“\(existing.label)” is already one of your tags, so it's selected for this recipe.")
        }
        do {
            let tag = try await RecipeLibrary.shared.createTag(trimmed)
            selectTag(tag.normalized)
            return nil
        } catch {
            return RecipeEditorNotice(title: "Couldn't save the tag", message: RecipeLibrary.shared.tagErrorMessage(error, label: trimmed))
        }
    }

    // MARK: Ingredients and steps

    /// Pasted lines ("2 1/2 lb chicken thighs", "- 3 eggs") become ingredient rows.
    func appendIngredients(from text: String) {
        let parsed = Self.lines(text)
            .map { Ingredients.parseLine(Self.stripBullet($0)) }
            .filter { !$0.name.recipeTrimmed.isEmpty }
            .map { RecipeIngredientDraft($0) }
        guard !parsed.isEmpty else { return }
        ingredients.removeAll { $0.isBlank }
        ingredients.append(contentsOf: parsed)
    }

    /// Pasted lines become steps, without their "1." or "Step 1:" numbers.
    func appendSteps(from text: String) {
        let parsed = Self.lines(text)
            .map { RecipeFormat.stripStepNumber(Self.stripBullet($0)) }
            .filter { !$0.isEmpty }
            .map { RecipeStepDraft(text: $0) }
        guard !parsed.isEmpty else { return }
        steps.removeAll { $0.text.recipeTrimmed.isEmpty }
        steps.append(contentsOf: parsed)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { String($0).recipeTrimmed }.filter { !$0.isEmpty }
    }

    static func stripBullet(_ line: String) -> String {
        line.replacingOccurrences(of: #"^[\-\*•·▢□◦‣]+\s*"#, with: "", options: .regularExpression).recipeTrimmed
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Photo

    /// A photo picked or taken, already cropped square.
    func setPhoto(_ jpeg: Data) {
        photoData = jpeg
        photoMimeType = "image/jpeg"
        imageURL = nil
        photoIsAI = false
    }

    func clearPhoto() {
        photoData = nil
        imageURL = nil
        photoIsAI = false
    }

    /// Generate with AI: needs a title, an ingredient and a step first; otherwise shows the
    /// hint for five seconds.
    func generateImage() async throws {
        guard canGenerateImage else {
            showsImageHint = true
            hintTask?.cancel()
            hintTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.showsImageHint = false
            }
            return
        }
        showsImageHint = false
        isGeneratingImage = true
        defer { isGeneratingImage = false }
        let response = try await api.generateRecipeImage(
            title: title.recipeTrimmed,
            description: details.recipeTrimmed.isEmpty ? nil : details.recipeTrimmed,
            tags: tags,
            ingredients: validIngredients.map { Ingredients.line($0) },
            instructions: validSteps
        )
        var base64 = response.dataBase64
        if base64.hasPrefix("data:"), let comma = base64.firstIndex(of: ",") {
            base64 = String(base64[base64.index(after: comma)...])
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw RecipeEditorError(message: "The generated photo couldn't be read. Try again.")
        }
        photoData = data
        photoMimeType = response.mimeType.isEmpty ? "image/png" : response.mimeType
        imageURL = nil
        photoIsAI = true
    }

    /// After AI fills in a recipe with no photo yet, make one (as the Expo app did).
    func generatePhotoIfMissing() {
        guard !hasPhoto, canGenerateImage, !isGeneratingImage else { return }
        Task { try? await generateImage() }
    }

    // MARK: Filling in from AI

    func createFromTranscript(_ transcript: String) async throws -> RecipeImportOutcome {
        isCreatingWithAI = true
        defer { isCreatingWithAI = false }
        let text = String(transcript.recipeTrimmed.prefix(12_000))
        let response = try await recipe(fromSpoken: text)
        let outcome = apply(response, notRecipeFallback: "That didn't look like a recipe. Try describing the ingredients and cooking steps.")
        if case .filled = outcome { generatePhotoIfMissing() }
        return outcome
    }

    /// A recipe from what someone said or typed. Always the API: writing a whole recipe from
    /// a short ask ("a casserole with chicken, broccoli and cheese") needs a bigger model than
    /// the one on the phone, which tends to use only the ingredients named. (The words are
    /// still heard on the phone.)
    private func recipe(fromSpoken text: String) async throws -> GeneratedRecipeResponse {
        try await api.recipeFromTranscript(text)
    }

    /// From a web page. Links pasted without https:// get it.
    func importLink(_ raw: String) async throws -> RecipeImportOutcome {
        let trimmed = raw.recipeTrimmed
        let url = trimmed.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil ? trimmed : "https://\(trimmed)"
        isImportingLink = true
        defer { isImportingLink = false }
        // Read the page on the device first (most sites publish the recipe as structured
        // data); the API reads it when the phone can't.
        let response: GeneratedRecipeResponse
        if let link = URL(string: url), let onDevice = await RecipeLinkImporter.importRecipe(from: link) {
            response = onDevice
        } else {
            response = try await api.recipeFromURL(url)
        }
        return apply(response, notRecipeFallback: "We couldn't find a recipe at that link.")
    }

    /// Photos of a cookbook page, a card or a screenshot (JPEG, up to 8).
    func scan(_ images: [Data]) async throws -> RecipeImportOutcome {
        guard !images.isEmpty else { return .nothingFound }
        isScanning = true
        defer { isScanning = false }
        // Read on the device when it can; the API reads the images otherwise.
        let pages = Array(images.prefix(8))
        let response: ScanRecipeDocumentResponse
        if let onDevice = await OnDeviceRecipeScanner.scan(pages) {
            response = onDevice
        } else {
            response = try await api.scanRecipe(images: pages)
        }
        var filled: [String] = []
        if let scannedTitle = response.title?.recipeTrimmed, !scannedTitle.isEmpty {
            title = scannedTitle
            filled.append("title")
        }
        let rows = response.ingredients.map { Ingredients.parseLine($0) }.filter { !$0.name.recipeTrimmed.isEmpty }
        if !rows.isEmpty {
            ingredients = rows.map { RecipeIngredientDraft($0) }
            filled.append("ingredients")
        }
        let stepRows = response.instructions.map(RecipeFormat.stripStepNumber).filter { !$0.isEmpty }
        if !stepRows.isEmpty {
            steps = stepRows.map { RecipeStepDraft(text: $0) }
            filled.append("steps")
        }
        if !filled.isEmpty { madeWithAI = true }
        return filled.isEmpty ? .nothingFound : .filled(filled)
    }

    /// Puts an AI-made recipe into the form, as the Expo app's applyGeneratedRecipeFields did.
    func apply(_ generated: GeneratedRecipeResponse, notRecipeFallback: String) -> RecipeImportOutcome {
        guard generated.isRecipe else {
            let reason = generated.failureReason?.recipeTrimmed ?? ""
            return .notRecipe(reason.isEmpty ? notRecipeFallback : reason)
        }
        var filled: [String] = []
        if let value = generated.title?.recipeTrimmed, !value.isEmpty {
            title = value
            filled.append("title")
        }
        if let value = generated.description?.recipeTrimmed, !value.isEmpty {
            details = value
            filled.append("description")
        }
        if let value = generated.baseServings, value.isFinite, value > 0 {
            servings = min(50, max(1, Int(value.rounded())))
            filled.append("servings")
        }
        let newTags = Self.unique(generated.tags.map { $0.recipeTrimmed.lowercased() })
        if !newTags.isEmpty {
            tags = Array(newTags.prefix(8))
            filled.append("tags")
        }
        let rows = generated.ingredients.map { Ingredients.parseLine($0) }.filter { !$0.name.recipeTrimmed.isEmpty }
        if !rows.isEmpty {
            ingredients = rows.map { RecipeIngredientDraft($0) }
            filled.append("ingredients")
        }
        let stepRows = generated.instructions.map(RecipeFormat.stripStepNumber).filter { !$0.isEmpty }
        if !stepRows.isEmpty {
            steps = stepRows.map { RecipeStepDraft(text: $0) }
            filled.append("steps")
        }
        if let minutes = generated.prepMinutes, minutes > 0 { prepText = String(minutes) }
        if let minutes = generated.cookMinutes, minutes > 0 { cookText = String(minutes) }
        if let level = generated.difficulty?.lowercased(), Self.difficulties.contains(level) { difficulty = level }
        if !filled.isEmpty { madeWithAI = true }
        return filled.isEmpty ? .nothingFound : .filled(filled)
    }

    // MARK: Saving

    /// Uploads a new photo, then creates or updates the recipe. New recipes are added to
    /// Favorites, as the Expo app did. Returns the recipe's id.
    func save() async throws -> String {
        isSaving = true
        defer { isSaving = false }
        applyTagRenames()

        let name = title.recipeTrimmed
        guard !name.isEmpty else { throw RecipeEditorError(message: "Give the recipe a title.") }
        guard !validIngredients.isEmpty else { throw RecipeEditorError(message: "Add at least one ingredient.") }
        guard !validSteps.isEmpty else { throw RecipeEditorError(message: "Add at least one step.") }
        guard !hasInvalidAmount else { throw RecipeEditorError(message: "Use a decimal (1.5), fraction (1/2), or mixed fraction (1 1/2) for amounts.") }

        if let photoData {
            let url = try await StorageClient.shared.uploadRecipePhoto(photoData, mimeType: photoMimeType)
            imageURL = url
            self.photoData = nil
        }
        guard let image = imageURL?.recipeTrimmed, !image.isEmpty else {
            throw RecipeEditorError(message: "Add a recipe photo before saving.")
        }

        let summary = details.recipeTrimmed
        let payload = RecipePayload(
            title: name,
            imageUrl: image,
            description: summary.isEmpty ? nil : summary,
            prepMinutes: Int(prepText.recipeTrimmed).map { max(0, $0) },
            cookMinutes: Int(cookText.recipeTrimmed).map { max(0, $0) },
            baseServings: Double(servings),
            difficulty: difficulty.isEmpty ? nil : difficulty,
            tags: tags,
            ingredients: validIngredients,
            instructions: validSteps
        )

        switch mode {
        case .create:
            let id = try await api.createRecipe(payload)
            try? await api.setFavorite(id, saved: true)
            initial = snapshot()
            return id
        case .edit(let recipe):
            try await api.updateRecipe(recipe.id, payload)
            initial = snapshot()
            return recipe.id
        }
    }
}
