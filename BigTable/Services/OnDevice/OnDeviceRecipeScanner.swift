import Foundation
import OSLog
import Vision

/// Reads a recipe from photos of a cookbook page, a recipe card or a screenshot on the
/// device: Vision reads the text, then Apple's on-device model picks out the main recipe.
/// Returns nil when it can't, or the result looks thin, and the caller sends the images to
/// the API as before.
nonisolated enum OnDeviceRecipeScanner {
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "OnDeviceScan")

    @concurrent static func scan(_ images: [Data]) async -> ScanRecipeDocumentResponse? {
        guard OnDeviceRecipeParser.isAvailable, !images.isEmpty else { return nil }
        var pages: [String] = []
        for image in images {
            guard let text = await recognizeText(in: image), !text.isEmpty else { continue }
            pages.append(text)
        }
        let text = pages.joined(separator: "\n")
        guard text.count >= 40 else { return nil }

        let excerpt = RecipeLinkImporter.recipeExcerpt(of: text)
        guard let parsed = await OnDeviceRecipeParser.parse(excerpt, from: .scan), parsed.isRecipe,
              parsed.ingredients.count >= 2, !parsed.instructions.isEmpty else { return nil }
        return ScanRecipeDocumentResponse(title: parsed.title, ingredients: parsed.ingredients, instructions: parsed.instructions)
    }

    /// The image's text, top to bottom, one line per line of text.
    private static func recognizeText(in image: Data) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            let observations = try await request.perform(on: image)
            return observations
                .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } catch {
            log.notice("On-device text recognition failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
