import Foundation
import OSLog

/// Reads a recipe from a web page on the device: most recipe sites publish the recipe as
/// schema.org data in the page, which is read exactly; otherwise the page's text goes to the
/// on-device model. A port of the API's lib/ai-recipe-url.ts. Returns nil when the page
/// couldn't be read here, and the caller asks the API instead.
nonisolated enum RecipeLinkImporter {
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "RecipeLink")
    private static let maxPageBytes = 5_000_000

    @concurrent static func importRecipe(from url: URL) async -> GeneratedRecipeResponse? {
        guard let html = await fetchHTML(url) else { return nil }
        if let structured = fromStructuredData(html) { return structured }
        let excerpt = recipeExcerpt(of: pageText(html))
        guard excerpt.count >= 40 else { return nil }
        // A page the small model calls "not a recipe" goes to the API for a second look.
        guard let parsed = await OnDeviceRecipeParser.parse(excerpt, from: .webPage), parsed.isRecipe else { return nil }
        return parsed
    }

    // MARK: Fetching

    private static func fetchHTML(_ url: URL) async -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(Locale.preferredLanguages.first.map { "\($0),en;q=0.8" } ?? "en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard type.isEmpty || type.contains("html") || type.contains("text/plain") else { return nil }
            let bytes = data.prefix(maxPageBytes)
            return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
        } catch {
            log.notice("Couldn't load the recipe page on device: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: schema.org Recipe

    static func fromStructuredData(_ html: String) -> GeneratedRecipeResponse? {
        let pattern = #"<script\b[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let bodyRange = Range(match.range(at: 1), in: html) else { continue }
            let raw = html[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let recipe = findRecipe(json) else { continue }

            let ingredients = strings(recipe["recipeIngredient"]).map(decodeEntities).filter { !$0.isEmpty }.prefix(80)
            let instructions = steps(recipe["recipeInstructions"]).map(decodeEntities).filter { !$0.isEmpty }.prefix(80)
            // Only trust structured data that carries the recipe itself.
            guard !ingredients.isEmpty, !instructions.isEmpty else { continue }

            let title = (recipe["name"] as? String).map { decodeEntities($0) }.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
            let description = (recipe["description"] as? String).map { decodeEntities($0) }.flatMap { $0.isEmpty ? nil : String($0.prefix(450)) }
            let tags = supportedTags(strings(recipe["keywords"]) + strings(recipe["recipeCategory"]) + strings(recipe["recipeCuisine"]))
            return GeneratedRecipeResponse(
                isRecipe: true,
                title: title,
                description: description,
                baseServings: servings(recipe["recipeYield"]),
                tags: tags,
                ingredients: Array(ingredients),
                instructions: Array(instructions),
                failureReason: nil,
                prepMinutes: minutes(recipe["prepTime"]),
                cookMinutes: minutes(recipe["cookTime"]) ?? minutes(recipe["totalTime"]).map { total in
                    max(0, total - (minutes(recipe["prepTime"]) ?? 0))
                }.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        return nil
    }

    /// The Recipe node, which may sit under @graph or in an array.
    private static func findRecipe(_ node: Any) -> [String: Any]? {
        if let array = node as? [Any] {
            for entry in array { if let found = findRecipe(entry) { return found } }
            return nil
        }
        guard let object = node as? [String: Any] else { return nil }
        let types: [String] = (object["@type"] as? [Any])?.compactMap { $0 as? String } ?? [(object["@type"] as? String) ?? ""]
        if types.contains(where: { $0.lowercased() == "recipe" }) { return object }
        if let graph = object["@graph"] { return findRecipe(graph) }
        return nil
    }

    /// Text values: a string (comma-separated), or an array of them.
    private static func strings(_ value: Any?) -> [String] {
        if let text = value as? String {
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let array = value as? [Any] { return array.flatMap { strings($0) } }
        return []
    }

    /// Steps from a string, HowToStep or HowToSection, in order.
    private static func steps(_ value: Any?) -> [String] {
        if let text = value as? String {
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard let array = value as? [Any] else {
            if let object = value as? [String: Any] { return steps([object]) }
            return []
        }
        var result: [String] = []
        for entry in array {
            if let text = entry as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
            } else if let object = entry as? [String: Any] {
                let type = (object["@type"] as? String) ?? ""
                if type.contains("HowToSection"), let items = object["itemListElement"] {
                    result.append(contentsOf: steps(items))
                } else if let text = (object["text"] as? String) ?? (object["name"] as? String) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { result.append(trimmed) }
                }
            }
        }
        return result
    }

    /// An ISO 8601 duration ("PT1H15M", "P0DT45M") in whole minutes.
    static func minutes(_ value: Any?) -> Int? {
        guard let text = (value as? String)?.uppercased(), text.hasPrefix("P") else { return nil }
        var total = 0.0
        for match in text.matches(of: #/(\d+(?:\.\d+)?)([DHMS])/#) {
            guard let number = Double(match.output.1) else { continue }
            switch match.output.2 {
            case "D": total += number * 1_440
            case "H": total += number * 60
            case "M":
                // In "P1M" (no T) M means months, which no recipe takes.
                guard text.contains("T") else { continue }
                total += number
            default: total += number / 60
            }
        }
        let rounded = Int(total.rounded())
        return (1...2_880).contains(rounded) ? rounded : nil
    }

    private static func servings(_ value: Any?) -> Double? {
        let candidates: [Any] = (value as? [Any]) ?? (value.map { [$0] } ?? [])
        for candidate in candidates {
            if let number = candidate as? NSNumber {
                let rounded = number.doubleValue.rounded()
                if (1...50).contains(rounded) { return rounded }
            }
            if let text = candidate as? String,
               let digits = text.firstMatch(of: #/\d+/#), let parsed = Double(digits.output), (1...50).contains(parsed) {
                return parsed
            }
        }
        return nil
    }

    private static func supportedTags(_ candidates: [String]) -> [String] {
        let allowed = Set(OnDeviceRecipeParser.supportedTags)
        var seen = Set<String>()
        var tags: [String] = []
        for candidate in candidates {
            let normalized = candidate.lowercased().trimmingCharacters(in: .whitespaces)
                .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == " " }
            guard allowed.contains(normalized), seen.insert(normalized).inserted else { continue }
            tags.append(normalized)
            if tags.count == 10 { break }
        }
        return tags
    }

    // MARK: Page text

    /// The page as readable lines, without scripts, styles and markup.
    static func pageText(_ html: String) -> String {
        var text = html
        for pattern in [#"<script\b[^>]*>[\s\S]*?</script>"#, #"<style\b[^>]*>[\s\S]*?</style>"#,
                        #"<noscript\b[^>]*>[\s\S]*?</noscript>"#, #"<head\b[^>]*>[\s\S]*?</head>"#, #"<!--[\s\S]*?-->"#] {
            text = replace(pattern, in: text, with: " ")
        }
        text = replace(#"<(p|div|li|br|h[1-6]|tr|section|article)\b[^>]*>"#, in: text, with: "\n")
        text = replace(#"<[^>]+>"#, in: text, with: " ")
        return decodeEntities(text)
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The part of the page around its ingredient list, sized for the on-device model.
    static func recipeExcerpt(of text: String) -> String {
        let limit = OnDeviceRecipeParser.maxInputCharacters - 200
        guard text.count > limit else { return text }
        guard let anchor = text.range(of: "ingredient", options: .caseInsensitive) else {
            return String(text.prefix(limit))
        }
        let start = text.index(anchor.lowerBound, offsetBy: -1_500, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start...].prefix(limit))
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        var text = value
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&#039;": "'", "&nbsp;": " ",
                     "&frac12;": "½", "&frac14;": "¼", "&frac34;": "¾", "&deg;": "°", "&ndash;": "–", "&mdash;": "—", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}"]
        for (entity, character) in named { text = text.replacingOccurrences(of: entity, with: character, options: .caseInsensitive) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: text), let codeRange = Range(match.range(at: 1), in: text) else { continue }
                let code = text[codeRange]
                let value = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let value, let scalar = Unicode.Scalar(value) { text.replaceSubrange(whole, with: String(Character(scalar))) }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
