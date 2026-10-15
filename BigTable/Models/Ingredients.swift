import Foundation

/// Ingredient amounts, measurements and lines, ported from the Expo app's
/// `lib/recipe-ingredients.ts` so both apps read and write recipes the same way.
nonisolated enum Ingredients {
    nonisolated struct Measurement: Hashable, Sendable, Identifiable {
        var label: String
        /// What's stored in `measurementType`. Empty for none.
        var value: String
        var short: String
        var id: String { value }
    }

    /// The measurement picker, in the Expo app's order.
    static let measurements: [Measurement] = [
        Measurement(label: "—", value: "", short: "—"),
        Measurement(label: "Each", value: "each", short: "ea"),
        Measurement(label: "Cup", value: "cup", short: "c"),
        Measurement(label: "Cups", value: "cups", short: "c"),
        Measurement(label: "Teaspoon", value: "tsp", short: "tsp"),
        Measurement(label: "Tablespoon", value: "tbsp", short: "tbsp"),
        Measurement(label: "Fluid Ounce", value: "floz", short: "fl oz"),
        Measurement(label: "Gram", value: "g", short: "g"),
        Measurement(label: "Milligram", value: "mg", short: "mg"),
        Measurement(label: "Kilogram", value: "kg", short: "kg"),
        Measurement(label: "Ounce", value: "oz", short: "oz"),
        Measurement(label: "Pound", value: "lb", short: "lb"),
        Measurement(label: "Milliliter", value: "ml", short: "ml"),
        Measurement(label: "Liter", value: "l", short: "l"),
        Measurement(label: "Pint", value: "pt", short: "pt"),
        Measurement(label: "Quart", value: "qt", short: "qt"),
        Measurement(label: "Gallon", value: "gal", short: "gal"),
        Measurement(label: "Pinch", value: "pinch", short: "pn"),
        Measurement(label: "Dash", value: "dash", short: "ds"),
        Measurement(label: "Packet", value: "packet", short: "pkt"),
        Measurement(label: "Bunch", value: "bunch", short: "bnch"),
        Measurement(label: "Sprig", value: "sprig", short: "sprg"),
        Measurement(label: "Stalk", value: "stalk", short: "stk"),
        Measurement(label: "Clove", value: "clove", short: "clv"),
        Measurement(label: "Head", value: "head", short: "hd"),
        Measurement(label: "Can", value: "can", short: "can"),
        Measurement(label: "Jar", value: "jar", short: "jar"),
        Measurement(label: "Bottle", value: "bottle", short: "btl"),
        Measurement(label: "Fillet", value: "fillet", short: "flt"),
        Measurement(label: "Slice", value: "slice", short: "slc"),
        Measurement(label: "Piece", value: "piece", short: "pc"),
    ]

    static func shortLabel(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return measurements.first { $0.value == value }?.short ?? value
    }

    private static let values: Set<String> = Set(measurements.map(\.value).filter { !$0.isEmpty })

    private static let aliases: [String: String] = [
        "each": "each", "ea": "each", "cup": "cup", "cups": "cups", "c": "cup",
        "teaspoon": "tsp", "teaspoons": "tsp", "tsp": "tsp", "tsps": "tsp", "t": "tsp",
        "tablespoon": "tbsp", "tablespoons": "tbsp", "tbsp": "tbsp", "tbsps": "tbsp", "tbl": "tbsp", "tbls": "tbsp", "tbs": "tbsp",
        "fluidounce": "floz", "fluidounces": "floz", "floz": "floz", "flounce": "floz",
        "gram": "g", "grams": "g", "g": "g", "milligram": "mg", "milligrams": "mg", "mg": "mg",
        "kilogram": "kg", "kilograms": "kg", "kg": "kg", "ounce": "oz", "ounces": "oz", "oz": "oz",
        "pound": "lb", "pounds": "lb", "lb": "lb", "lbs": "lb",
        "milliliter": "ml", "milliliters": "ml", "ml": "ml", "liter": "l", "liters": "l", "l": "l",
        "pint": "pt", "pints": "pt", "pt": "pt", "quart": "qt", "quarts": "qt", "qt": "qt",
        "gallon": "gal", "gallons": "gal", "gal": "gal",
        "pinch": "pinch", "dash": "dash", "packet": "packet", "packets": "packet",
        "bunch": "bunch", "bunches": "bunch", "sprig": "sprig", "sprigs": "sprig",
        "stalk": "stalk", "stalks": "stalk", "clove": "clove", "cloves": "clove",
        "head": "head", "heads": "head", "can": "can", "cans": "can", "jar": "jar", "jars": "jar",
        "bottle": "bottle", "bottles": "bottle", "fillet": "fillet", "fillets": "fillet",
        "slice": "slice", "slices": "slice", "piece": "piece", "pieces": "piece",
    ]

    static func measurement(for word: String) -> String? {
        let normalized = word.lowercased().filter { $0.isLetter && $0.isASCII }
        guard !normalized.isEmpty else { return nil }
        if values.contains(normalized) { return normalized }
        return aliases[normalized]
    }

    private static let vulgar: [Character: String] = [
        "\u{00BC}": "1/4", "\u{00BD}": "1/2", "\u{00BE}": "3/4", "\u{2150}": "1/7", "\u{2151}": "1/9",
        "\u{2152}": "1/10", "\u{2153}": "1/3", "\u{2154}": "2/3", "\u{2155}": "1/5", "\u{2156}": "2/5",
        "\u{2157}": "3/5", "\u{2158}": "4/5", "\u{2159}": "1/6", "\u{215A}": "5/6", "\u{215B}": "1/8",
        "\u{215C}": "3/8", "\u{215D}": "5/8", "\u{215E}": "7/8",
    ]

    /// "1½" → "1 1/2", "1-1/2" → "1 1/2", odd spaces to plain ones.
    static func normalizeAmountText(_ value: String) -> String {
        var text = value.map { vulgar[$0] ?? String($0) }.joined()
        text = text.replacingOccurrences(of: "\u{2044}", with: "/")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        text = text.replacingOccurrences(of: #"(\d)-(?=\d+/\d+)"#, with: "$1 ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\d)(\d+/\d+)"#, with: "$1 $2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// "1 1/2", "3/4", "2.5" → a number; anything else → nil.
    static func parseAmount(_ value: String) -> Double? {
        let text = normalizeAmountText(value)
        guard !text.isEmpty else { return nil }
        if let match = text.wholeMatch(of: #/(\d+)\s+(\d+)\/(\d+)/#), let whole = Double(match.1), let n = Double(match.2), let d = Double(match.3), d != 0 {
            return whole + n / d
        }
        if let match = text.wholeMatch(of: #/(\d+)\/(\d+)/#), let n = Double(match.1), let d = Double(match.2), d != 0 {
            return n / d
        }
        if let match = text.wholeMatch(of: #/\d+(?:\.\d+)?/#) {
            return Double(match.output)
        }
        return nil
    }

    /// 1.5 → "1.5", 2 → "2", 0.333 → "0.33", as the Expo app wrote amounts.
    static func formatAmount(_ amount: Double?) -> String {
        guard let amount, amount.isFinite else { return "" }
        let rounded = (amount * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.2f", rounded)
        if text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// Kitchen-friendly display: 1.5 → "1 ½", 0.25 → "¼".
    static func displayAmount(_ amount: Double?) -> String {
        guard let amount, amount > 0 else { return "" }
        return Fraction.format(amount)
    }

    /// "1 ½ cup flour" for a list or a share.
    static func line(_ ingredient: RecipeIngredientInput) -> String {
        [displayAmount(ingredient.amount), shortLabel(ingredient.measurementType), ingredient.name.trimmingCharacters(in: .whitespaces)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The plain line the API's AI endpoints take: "1.5 cup flour".
    static func plainLine(_ ingredient: RecipeIngredientInput) -> String {
        [formatAmount(ingredient.amount), ingredient.measurementType ?? "", ingredient.name.trimmingCharacters(in: .whitespaces)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Reads "2 1/2 lb chicken thighs", "1/2cup sugar", "3 eggs", "Salt to taste".
    static func parseLine(_ line: String) -> RecipeIngredientInput {
        let text = normalizeAmountText(line)
        guard !text.isEmpty else { return RecipeIngredientInput(amount: nil, measurementType: nil, name: "") }

        // "1 1/2cups flour", "1/2cup", "2tbsp": an amount stuck to its measurement.
        if let match = text.wholeMatch(of: #/(\d+\s+\d+\/\d+|\d+\/\d+|\d+(?:\.\d+)?)([a-zA-Z]+)(?:\s+(.*))?/#) {
            return parseAmountAndMeasurement(String(match.1), String(match.2), match.3.map(String.init))
        }
        if let match = text.wholeMatch(of: #/(\d+\s+\d+\/\d+|\d+\/\d+|\d+(?:\.\d+)?)(?:\s+(.*))?/#) {
            return parseAmount(String(match.1), remainder: match.2.map(String.init))
        }
        return RecipeIngredientInput(amount: nil, measurementType: nil, name: text)
    }

    private static func parseAmount(_ amountText: String, remainder: String?) -> RecipeIngredientInput {
        guard let amount = parseAmount(amountText) else {
            return RecipeIngredientInput(amount: nil, measurementType: nil, name: remainder?.trimmingCharacters(in: .whitespaces) ?? amountText)
        }
        let rest = (remainder ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return RecipeIngredientInput(amount: amount, measurementType: nil, name: "") }
        var words = rest.split(separator: " ").map(String.init)
        if let measurement = Self.measurement(for: words[0]) {
            words.removeFirst()
            return RecipeIngredientInput(amount: amount, measurementType: measurement, name: words.joined(separator: " "))
        }
        return RecipeIngredientInput(amount: amount, measurementType: nil, name: rest)
    }

    private static func parseAmountAndMeasurement(_ amountText: String, _ measurementText: String, _ remainder: String?) -> RecipeIngredientInput {
        guard let amount = parseAmount(amountText) else {
            return RecipeIngredientInput(amount: nil, measurementType: nil, name: "\(amountText)\(measurementText)\(remainder.map { " \($0)" } ?? "")".trimmingCharacters(in: .whitespaces))
        }
        guard let measurement = Self.measurement(for: measurementText) else {
            return RecipeIngredientInput(amount: amount, measurementType: nil, name: "\(measurementText)\(remainder.map { " \($0)" } ?? "")".trimmingCharacters(in: .whitespaces))
        }
        let name = (remainder ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return RecipeIngredientInput(amount: amount, measurementType: measurement, name: name)
    }
}

/// Kitchen fractions: amounts round to the nearest eighth, third or quarter people measure.
nonisolated enum Fraction {
    private static let glyphs: [(Double, String)] = [
        (0.125, "⅛"), (0.25, "¼"), (1.0 / 3, "⅓"), (0.375, "⅜"), (0.5, "½"),
        (0.625, "⅝"), (2.0 / 3, "⅔"), (0.75, "¾"), (0.875, "⅞"),
    ]

    static func format(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        if value >= 10 { return String(Int(value.rounded())) }
        var whole = Int(value)
        let rest = value - Double(whole)
        let candidates = [(0.0, "")] + glyphs + [(1.0, "")]
        let nearest = candidates.min { abs($0.0 - rest) < abs($1.0 - rest) } ?? (0, "")
        if nearest.0 == 1 { whole += 1 }
        let glyph = nearest.0 == 1 ? "" : nearest.1
        switch (whole, glyph.isEmpty) {
        case (0, true): return glyphs[0].1
        case (0, false): return glyph
        case (_, true): return String(whole)
        default: return "\(whole) \(glyph)"
        }
    }
}
