import Foundation
import FoundationModels
import OSLog

/// One thing someone told the pantry.
nonisolated struct PantrySpoken: Hashable, Sendable {
    nonisolated enum Kind: String, Sendable {
        /// "I have 4 lb of rice."
        case set
        /// "We bought two more dozen eggs."
        case add
        /// "We're out of maple syrup."
        case out
        /// "Milk is low."
        case low
        /// "The flour bin is about a third full."
        case level
    }

    var kind: Kind
    var name: String
    var amount: Double?
    var unit: String?
    /// For `level`: 0–1.
    var level: Double?
    var containerName: String?
    var placeName: String?
    /// The words it came from, to underline in the transcript.
    var phrase: String
}

/// Turns what someone said into pantry changes: plain rules first (amounts, "out of",
/// "is low", "the bin is a third full"), then Apple's on-device model for the rest, with the
/// family's own item and container names to choose from.
nonisolated enum PantryVoiceParser {
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "PantryVoice")

    static func parse(_ text: String, itemNames: [String], containerNames: [String]) async -> [PantrySpoken] {
        var found: [PantrySpoken] = []
        var leftovers: [String] = []
        for clause in clauses(text) {
            if let spoken = rule(clause, containerNames: containerNames) {
                found.append(spoken)
            } else if clause.split(separator: " ").count >= 2 {
                leftovers.append(clause)
            }
        }
        if !leftovers.isEmpty, let modeled = await model(leftovers.joined(separator: ". "), itemNames: itemNames, containerNames: containerNames) {
            found += modeled
        }
        return found
    }

    // MARK: Clauses

    /// "I have 4 pounds of rice, 8 pounds of black beans, and we're out of syrup" → three.
    static func clauses(_ text: String) -> [String] {
        let separated = text
            .replacingOccurrences(of: #"[.;!?\n]"#, with: ",", options: .regularExpression)
            .replacingOccurrences(of: #",?\s+and\s+(?=(we|i|the|there|my|our|a|an|\d|one|two|three|four|five|six|seven|eight|nine|ten|half)\b)"#, with: ",", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #",?\s+also\s+"#, with: ",", options: [.regularExpression, .caseInsensitive])
        var result: [String] = []
        var carry = ""
        for part in separated.split(separator: ",") {
            var clause = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if clause.isEmpty { continue }
            // "I have 4 lb of rice, 8 lb of beans": the second inherits "I have".
            if let lead = clause.lowercased().firstMatch(of: #/^(i have|we have|i've got|we've got|we got|i got|i bought|we bought|there's|there is|there are)\b/#) {
                carry = String(lead.output.1)
            } else if !carry.isEmpty, startsWithAmount(clause) {
                clause = carry + " " + clause
            }
            result.append(clause)
        }
        return result
    }

    static func startsWithAmount(_ clause: String) -> Bool {
        let first = clause.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return Double(first) != nil || numberWords[first] != nil || first.contains("/")
    }

    // MARK: Rules

    static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "half": 0.5, "couple": 2,
        "few": 3, "dozen": 12,
    ]

    static let fractions: [(String, Double)] = [
        ("almost empty", 0.1), ("nearly empty", 0.1), ("almost full", 0.9), ("nearly full", 0.9),
        ("two thirds", 0.67), ("three quarters", 0.75), ("three fourths", 0.75), ("a third", 0.33), ("one third", 0.33),
        ("a quarter", 0.25), ("one quarter", 0.25), ("a fourth", 0.25), ("half", 0.5), ("full", 1), ("empty", 0),
    ]

    static let containerWords = ["bin", "bucket", "canister", "jar", "container", "tub", "crock", "tin"]

    static func rule(_ clause: String, containerNames: [String]) -> PantrySpoken? {
        let lower = clause.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // "We're out of maple syrup" / "out of eggs"
        if let match = lower.firstMatch(of: #/(?:we're|we are|i'm|i am|we|i)?\s*(?:all\s+)?out of\s+(?:the\s+)?(.+)$/#) {
            return PantrySpoken(kind: .out, name: clean(String(match.output.1)), phrase: clause)
        }
        // "Milk is low" / "we're low on milk" / "running low on bread"
        if let match = lower.firstMatch(of: #/(?:we're|we are|running)?\s*low on\s+(?:the\s+)?(.+)$/#) {
            return PantrySpoken(kind: .low, name: clean(String(match.output.1)), phrase: clause)
        }
        if let match = lower.firstMatch(of: #/^(?:the\s+)?(.+?)\s+(?:is|are)\s+(?:getting\s+|running\s+)?low$/#) {
            return PantrySpoken(kind: .low, name: clean(String(match.output.1)), phrase: clause)
        }
        // "The flour bin is about a third full"
        if let match = lower.firstMatch(of: #/^(?:the\s+)?(.+?)(?:\s+is|'s|’s)\s+(?:about\s+|around\s+|maybe\s+|like\s+)?(.+?)(?:\s+full)?$/#) {
            let subject = String(match.output.1)
            let rest = String(match.output.2)
            let isContainer = containerWords.contains { subject.hasSuffix($0) } || containerNames.contains { PantryNames.canonical($0) == PantryNames.canonical(subject) }
            if isContainer, let level = fractions.first(where: { rest.contains($0.0) })?.1 {
                return PantrySpoken(kind: .level, name: subject, level: level, containerName: subject, phrase: clause)
            }
        }
        // "I have 4 pounds of white rice in the garage" / "bought two dozen eggs" / "8 lb black beans"
        var body = lower
        var kind: PantrySpoken.Kind = .set
        if let lead = lower.firstMatch(of: #/^(i have|we have|i've got|we've got|we got|i got|i bought|we bought|picked up|there's|there is|there are|we still have|still have)\s+(.+)$/#) {
            let verb = String(lead.output.1)
            kind = ["we got", "i got", "i bought", "we bought", "picked up"].contains(verb) ? .add : .set
            body = String(lead.output.2)
        }
        if body.hasPrefix("another ") || body.contains(" more ") { kind = .add }
        var place: String?
        if let at = body.firstMatch(of: #/^(.+?)\s+(?:in|on)\s+(?:the\s+)?(fridge|freezer|pantry|garage|basement|deep freezer|chest freezer|cupboard|shed)$/#) {
            body = String(at.output.1)
            place = String(at.output.2)
        }
        guard let parsed = amountAndName(body) else { return nil }
        return PantrySpoken(kind: kind, name: parsed.name, amount: parsed.amount, unit: parsed.unit, placeName: place, phrase: clause)
    }

    /// "4 pounds of white rice" → 4, "lb", "white rice". "two dozen eggs" → 24, "", "eggs".
    static func amountAndName(_ text: String) -> (amount: Double, unit: String, name: String)? {
        var words = text.replacingOccurrences(of: "another ", with: "one ").replacingOccurrences(of: " more ", with: " ")
            .split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        var amount: Double
        if let number = Double(first) {
            amount = number
        } else if first.contains("/"), let value = Ingredients.parseAmount(first) {
            amount = value
        } else if let number = numberWords[first] {
            amount = number
        } else {
            return nil
        }
        words.removeFirst()
        // "a half", "and a half", "1 1/2"
        if let next = words.first, next.contains("/"), let part = Ingredients.parseAmount(next) {
            amount += part
            words.removeFirst()
        }
        if words.starts(with: ["and", "a", "half"]) {
            amount += 0.5
            words.removeFirst(3)
        }
        if words.first == "dozen" {
            amount *= 12
            words.removeFirst()
        }
        var unit = ""
        if let next = words.first {
            let normalized = PantryUnits.normalized(next)
            if PantryUnits.weight[normalized] != nil || PantryUnits.volume[normalized] != nil || (PantryUnits.count[normalized] != nil && !normalized.isEmpty) {
                unit = normalized
                words.removeFirst()
            }
        }
        if words.first == "of" { words.removeFirst() }
        let name = clean(words.joined(separator: " "))
        guard !name.isEmpty else { return nil }
        return (amount, unit, name)
    }

    static func clean(_ name: String) -> String {
        name.replacingOccurrences(of: #"^(the|some|our|my)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(left|left over|in there)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    // MARK: The on-device model

    private static func model(_ text: String, itemNames: [String], containerNames: [String]) async -> [PantrySpoken]? {
        guard OnDeviceRecipeParser.isAvailable else { return nil }
        let instructions = """
            You update a family's pantry from what they said. For each thing they mention, give one change.
            kind is set (they have this much), add (they bought more), out (they have none), low (running low), or level (a container's fill, 0 to 1).
            Use one of these item names when it's the same thing: \(itemNames.prefix(80).joined(separator: ", ")).
            Their containers: \(containerNames.joined(separator: ", ")).
            Units are lb, oz, cup, gal, qt, each, dozen, can, jar, bag. Leave out anything that isn't about food they have.
            """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "They said: \(text)", generating: SpokenPantryChanges.self, options: GenerationOptions(temperature: 0.1))
            return response.content.changes.compactMap { change in
                let name = change.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let kind = PantrySpoken.Kind(rawValue: change.kind) else { return nil }
                return PantrySpoken(
                    kind: kind, name: name, amount: change.amount, unit: change.unit,
                    level: kind == .level ? change.amount.map { min(1, max(0, $0)) } : nil,
                    containerName: kind == .level ? name : nil, phrase: text
                )
            }
        } catch {
            log.notice("On-device pantry parse failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

@Generable
nonisolated struct SpokenPantryChanges {
    var changes: [SpokenPantryChange]
}

@Generable
nonisolated struct SpokenPantryChange {
    @Guide(description: "set, add, out, low or level")
    var kind: String
    @Guide(description: "The food, or the container for level")
    var name: String
    @Guide(description: "How much, or the fill from 0 to 1 for level")
    var amount: Double?
    @Guide(description: "The unit, like lb, cup, gal or each")
    var unit: String?
}
