import Foundation

// MARK: - Names

/// Matching names across recipes, receipts, the grocery list and what people say: "KS ORG
/// EGGS 24CT", "2 large eggs, beaten" and "eggs" all come out as "egg".
nonisolated enum PantryNames {
    private static let dropWords: Set<String> = [
        "fresh", "large", "small", "medium", "extra", "jumbo", "organic", "org", "ks", "kirkland", "signature",
        "great", "value", "chopped", "minced", "diced", "sliced", "beaten", "softened", "melted", "divided",
        "to", "taste", "of", "packed", "cold", "warm", "room", "temperature", "finely", "roughly", "thinly",
        "peeled", "cubed", "grated", "rinsed", "drained", "optional", "about", "plus", "more", "for", "serving",
        "the", "a", "an", "and", "or", "lightly", "freshly", "whole", "boneless", "skinless", "bnls", "sknls",
        "ct", "pk", "pack", "bag", "box", "lb", "lbs", "oz", "can", "cans", "jar", "bottle", "dozen", "gal", "gallon",
    ]

    /// Short receipt words that mean something.
    private static let receiptWords: [String: String] = [
        "shrd": "shredded", "mozz": "mozzarella", "chs": "cheese", "chkn": "chicken", "grnd": "ground", "bf": "beef",
        "tort": "tortilla", "flr": "flour", "frz": "frozen", "blueberry": "blueberry", "pb": "peanut butter",
        "pnt": "peanut", "btr": "butter", "ylw": "yellow", "onion": "onion", "bnna": "banana", "thigh": "thigh",
    ]

    /// Lowercased, singular, without brands, sizes, prep words or anything in brackets.
    static func canonical(_ text: String) -> String {
        var name = text.lowercased()
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        if let comma = name.firstIndex(of: ",") { name = String(name[..<comma]) }
        let words = name
            .replacingOccurrences(of: #"[0-9]+(\.[0-9]+)?[#%]?"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z\s'-]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map { receiptWords[String($0)] ?? String($0) }
            .flatMap { $0.split(separator: " ").map(String.init) }
            .filter { !dropWords.contains($0) && $0.count > 1 }
            .map(singular)
        return words.joined(separator: " ")
    }

    static func singular(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("oes"), word.count > 4 { return String(word.dropLast(2)) }
        if word.hasSuffix("ches") || word.hasSuffix("shes") || word.hasSuffix("xes") { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), word.count > 3 { return String(word.dropLast()) }
        return word
    }

    /// How well two canonical names match: 1 the same, 0.8 one's words all in the other, else 0.
    static func score(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let left = Set(a.split(separator: " ")), right = Set(b.split(separator: " "))
        if left.isSubset(of: right) || right.isSubset(of: left) { return 0.8 }
        return 0
    }

    /// The best item for a name, when it's a good enough match.
    static func match(_ text: String, in items: [PantryItem]) -> PantryItem? {
        let key = canonical(text)
        let raw = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let alias = items.first(where: { $0.aliases.contains(raw) || $0.aliases.contains(key) }) { return alias }
        let scored = items.map { ($0, score(key, $0.canonical)) }.filter { $0.1 >= 0.8 }
        return scored.max { $0.1 < $1.1 }?.0
    }
}

// MARK: - Units

/// Converting what recipes, receipts and people say into an item's base unit (pounds, cups,
/// or a count), and back for showing.
nonisolated enum PantryUnits {
    /// Pounds per unit.
    static let weight: [String: Double] = ["lb": 1, "oz": 1.0 / 16, "g": 1.0 / 453.6, "kg": 2.2046, "mg": 1.0 / 453_600]
    /// Cups per unit.
    static let volume: [String: Double] = [
        "cup": 1, "cups": 1, "tsp": 1.0 / 48, "tbsp": 1.0 / 16, "floz": 1.0 / 8, "ml": 1.0 / 236.6, "l": 4.227,
        "pt": 2, "qt": 4, "gal": 16, "pinch": 1.0 / 768, "dash": 1.0 / 384,
    ]
    /// Counted things; a dozen is 12.
    static let count: [String: Double] = [
        "": 1, "each": 1, "piece": 1, "can": 1, "jar": 1, "bottle": 1, "clove": 1, "head": 1, "bunch": 1,
        "packet": 1, "slice": 1, "fillet": 1, "stalk": 1, "sprig": 1, "dozen": 12, "bag": 1, "box": 1, "pack": 1,
    ]

    /// Cups per pound for things measured both ways (recipes in cups, bought by the pound).
    static let cupsPerPound: [String: Double] = [
        "cheese": 4, "cheddar": 4, "mozzarella": 4, "parmesan": 4.5, "flour": 3.6, "sugar": 2.25, "brown sugar": 2.3,
        "powdered sugar": 3.75, "rice": 2.3, "oat": 5, "butter": 2, "pasta": 4, "macaroni": 4, "bean": 2.4,
        "lentil": 2.3, "chocolate chip": 2.7, "raisin": 2.8, "nut": 3.5, "almond": 3.3, "walnut": 4, "pecan": 4,
        "honey": 0.67, "peanut butter": 1.9, "coffee": 5, "cornmeal": 3, "breadcrumb": 4, "spinach": 16,
        "ground beef": 2, "chicken": 2.5, "yogurt": 2, "sour cream": 2, "cream cheese": 2,
    ]

    /// "lb" → weight, "cup" → volume, "can" → count. Unknown words count.
    static func kind(of unit: String) -> PantryUnitKind {
        let unit = normalized(unit)
        if weight[unit] != nil { return .weight }
        if volume[unit] != nil { return .volume }
        return .count
    }

    static func normalized(_ unit: String?) -> String {
        let raw = (unit ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "" }
        let aliases: [String: String] = [
            "pound": "lb", "pounds": "lb", "lbs": "lb", "#": "lb", "ounce": "oz", "ounces": "oz", "gram": "g", "grams": "g",
            "kilogram": "kg", "kilograms": "kg", "cups": "cup", "teaspoon": "tsp", "teaspoons": "tsp", "tablespoon": "tbsp",
            "tablespoons": "tbsp", "gallon": "gal", "gallons": "gal", "quart": "qt", "quarts": "qt", "pint": "pt", "pints": "pt",
            "liter": "l", "liters": "l", "milliliter": "ml", "milliliters": "ml", "dozens": "dozen", "cans": "can", "jars": "jar",
            "bottles": "bottle", "cloves": "clove", "heads": "head", "bunches": "bunch", "bags": "bag", "boxes": "box",
            "packs": "pack", "packages": "pack", "package": "pack", "ct": "each", "count": "each", "pieces": "piece",
            "fl oz": "floz", "slices": "slice",
        ]
        return aliases[raw] ?? raw
    }

    /// An amount in `unit` as the item's base unit, or nil when it can't be converted.
    static func toBase(_ amount: Double, unit: String?, for item: PantryItem) -> Double? {
        toBase(amount, unit: unit, kind: item.kind, canonical: item.canonical)
    }

    static func toBase(_ amount: Double, unit: String?, kind: PantryUnitKind, canonical: String) -> Double? {
        let unit = normalized(unit)
        switch kind {
        case .weight:
            if let pounds = weight[unit] { return amount * pounds }
            if let cups = volume[unit], let density = density(for: canonical) { return amount * cups / density }
            return nil
        case .volume:
            if let cups = volume[unit] { return amount * cups }
            if let pounds = weight[unit], let density = density(for: canonical) { return amount * pounds * density }
            return nil
        case .count:
            if let each = count[unit] { return amount * each }
            return nil
        }
    }

    static func density(for canonical: String) -> Double? {
        if let exact = cupsPerPound[canonical] { return exact }
        let words = canonical.split(separator: " ").map(String.init)
        for size in stride(from: min(words.count, 2), through: 1, by: -1) {
            for start in 0...(words.count - size) {
                let key = words[start..<(start + size)].joined(separator: " ")
                if let value = cupsPerPound[key] { return value }
            }
        }
        return nil
    }

    /// A base amount as the item shows it: "1.5 lb", "6 cups", "4 dozen", "12".
    static func display(_ base: Double, for item: PantryItem) -> String {
        let unit = normalized(item.displayUnit)
        let amount: Double
        switch item.kind {
        case .weight: amount = base / (weight[unit] ?? 1)
        case .volume: amount = base / (volume[unit] ?? 1)
        case .count: amount = base / (count[unit] ?? 1)
        }
        let number = Ingredients.formatAmount((amount * 10).rounded() / 10)
        switch unit {
        case "", "each", "piece": return number
        case "cup": return number + (amount == 1 ? " cup" : " cups")
        case "dozen": return number + " dozen"
        case "can", "jar", "bottle", "bag", "box", "pack", "head", "bunch", "packet":
            return number + " " + (amount == 1 ? unit : unit + "s")
        default: return number + " " + Ingredients.shortLabel(unit)
        }
    }

    /// The unit to show a new item in, from the unit it first came in.
    static func displayUnit(for unit: String?, kind: PantryUnitKind) -> String {
        let unit = normalized(unit)
        switch kind {
        case .weight: return weight[unit] != nil ? (unit == "g" || unit == "mg" ? "lb" : unit) : "lb"
        case .volume: return volume[unit] != nil ? (["tsp", "tbsp", "pinch", "dash", "ml"].contains(unit) ? "cup" : unit) : "cup"
        case .count: return unit == "dozen" ? "dozen" : (count[unit] != nil ? unit : "")
        }
    }
}

// MARK: - Amounts

/// What the ledger says about one item now.
nonisolated struct PantryAmount: Hashable, Sendable {
    /// In the item's base unit.
    var amount: Double
    /// 0–1. Under 0.5 is a guess the quick check asks about.
    var confidence: Double
    /// The amount after the last time it was bought or set, to show how full it is.
    var full: Double
    var lastAdded: Date?
    var lastSure: Date?
    /// When the family bought it, oldest first (for how often they buy it).
    var addDates: [Date]

    var level: Double { full > 0 ? min(1, max(0, amount / full)) : (amount > 0 ? 1 : 0) }
    var isOut: Bool { amount <= 0.0001 }
    var isUnsure: Bool { confidence < 0.5 }

    static let unknown = PantryAmount(amount: 0, confidence: 0, full: 0, lastAdded: nil, lastSure: nil, addDates: [])
}

/// Adds up change records into amounts, and plans forward over the meal plan.
nonisolated enum PantryLedger {
    static func amounts(_ pantry: KitchenPantry) -> [String: PantryAmount] {
        var result: [String: PantryAmount] = [:]
        let containers = pantry.containers
        for change in pantry.changes.values.sorted(by: { $0.at < $1.at }) {
            var value = result[change.itemID] ?? .unknown
            switch change.kind {
            case .set:
                value.amount = max(0, change.amount ?? 0)
                value.confidence = change.confidence
                value.full = max(value.amount, value.full)
                value.lastSure = change.at
            case .level:
                let capacity = change.containerID.flatMap { containers[$0]?.capacity } ?? value.full
                value.amount = max(0, (change.amount ?? 0) * capacity)
                value.full = max(capacity, value.amount)
                value.confidence = change.confidence
                value.lastSure = change.at
            case .add:
                let wasEmpty = value.amount <= 0.0001
                value.amount += max(0, change.amount ?? 0)
                value.confidence = wasEmpty ? change.confidence : min(1, (value.confidence + change.confidence) / 2 + 0.2)
                value.full = value.amount
                value.lastAdded = change.at
                if change.source == .receipt || change.source == .checkoff { value.addDates.append(change.at) }
                if change.confidence >= 0.9 && wasEmpty { value.lastSure = change.at }
            case .use:
                if let amount = change.amount {
                    value.amount = max(0, value.amount - amount)
                    value.confidence *= change.source == .cooked ? 0.88 : 0.97
                } else {
                    value.confidence *= 0.7
                }
            }
            result[change.itemID] = value
        }
        return result
    }

    // MARK: Shopping day

    /// The family's usual shopping day: the most common weekday of the last 8 weeks' receipts,
    /// else a week from today. The next one after `now`.
    static func nextShop(_ pantry: KitchenPantry, now: Date = .now, calendar: Calendar = .current) -> Date {
        let since = now.addingTimeInterval(-56 * 86_400)
        let days = pantry.changes.values
            .filter { $0.source == .receipt && $0.at > since }
            .map { calendar.startOfDay(for: $0.at) }
        let trips = Set(days)
        var counts: [Int: Int] = [:]
        for day in trips { counts[calendar.component(.weekday, from: day), default: 0] += 1 }
        let today = calendar.startOfDay(for: now)
        guard let weekday = counts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key, trips.count >= 2 else {
            return calendar.date(byAdding: .day, value: 7, to: today) ?? now
        }
        for offset in 1...7 {
            if let day = calendar.date(byAdding: .day, value: offset, to: today), calendar.component(.weekday, from: day) == weekday {
                return day
            }
        }
        return calendar.date(byAdding: .day, value: 7, to: today) ?? now
    }

    // MARK: Running out

    /// One planned meal's use of an item.
    nonisolated struct PlannedUse: Hashable, Sendable {
        var date: String
        var slot: MealSlotType
        var slotKey: String
        var mealTitle: String
        /// Base units, or nil when the recipe's unit can't be converted.
        var amount: Double?
    }

    nonisolated struct Shortfall: Hashable, Sendable {
        var itemID: String
        /// The meal it runs short at (nil for "out by" a usage-rate guess).
        var use: PlannedUse?
        /// Base units missing at that meal.
        var missing: Double
        /// When it runs out, for the badge ("Short Fri", "Out Sat").
        var date: String
        /// Short at a meal (sure), or out by how often they buy it (a guess).
        var isGuess: Bool
    }

    /// Walks the planned meals in order from the current amount; the first one that goes below
    /// zero is where it runs short.
    static func shortfall(item: PantryItem, amount: PantryAmount, uses: [PlannedUse]) -> Shortfall? {
        var left = amount.amount
        for use in uses {
            guard let need = use.amount else { continue }
            left -= need
            if left < -0.0001 {
                return Shortfall(itemID: item.id, use: use, missing: -left, date: use.date, isGuess: false)
            }
        }
        return nil
    }

    /// For things no recipe uses (milk, bananas): out by the usual gap between buys.
    static func outByRate(item: PantryItem, amount: PantryAmount, before shop: Date, calendar: Calendar = .current) -> Shortfall? {
        guard amount.addDates.count >= 2, let last = amount.lastAdded else { return nil }
        let dates = amount.addDates.suffix(4)
        let gaps = zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) }.filter { $0 > 86_400 }
        guard !gaps.isEmpty else { return nil }
        let gap = gaps.reduce(0, +) / Double(gaps.count)
        let out = last.addingTimeInterval(gap)
        guard shop > out, out > Date.now else { return nil }
        return Shortfall(itemID: item.id, use: nil, missing: 0, date: ISODay.string(from: out, calendar: calendar), isGuess: true)
    }

    // MARK: Use it up

    /// Days things keep once bought (fridge and pantry; the freezer keeps things for months).
    static let shelfDays: [(String, Int)] = [
        ("spinach", 5), ("lettuce", 5), ("greens", 5), ("arugula", 4), ("berry", 5), ("strawberry", 5), ("raspberry", 3),
        ("cilantro", 7), ("parsley", 7), ("basil", 5), ("avocado", 4), ("banana", 6), ("mushroom", 6), ("sour cream", 21),
        ("heavy cream", 10), ("cream", 10), ("milk", 10), ("yogurt", 14), ("bread", 7), ("tortilla", 14), ("chicken", 2),
        ("ground beef", 2), ("beef", 4), ("pork", 4), ("turkey", 2), ("fish", 2), ("salmon", 2), ("shrimp", 2),
        ("ricotta", 7), ("cottage cheese", 7), ("hummus", 7), ("tomato", 7), ("cucumber", 7), ("zucchini", 7),
    ]

    static func shelfLife(for canonical: String) -> Int? {
        shelfDays.first { canonical == $0.0 || canonical.hasSuffix(" " + $0.0) || canonical.contains($0.0) }?.1
    }

    /// Days left before it should be used, when that's 3 or fewer.
    static func daysLeft(item: PantryItem, place: PantryPlace?, amount: PantryAmount, now: Date = .now) -> Int? {
        guard place?.kind != .freezer, !amount.isOut, let bought = amount.lastAdded, let life = shelfLife(for: item.canonical) else { return nil }
        let age = Int(now.timeIntervalSince(bought) / 86_400)
        let left = life - age
        return left <= 3 ? max(0, left) : nil
    }

    // MARK: Swaps

    /// Stand-ins that are always safe for each other (same kind of food, so the same
    /// allergies). Never from the model.
    static let swapGroups: [[String]] = [
        ["cheddar", "mozzarella", "monterey jack", "colby jack", "pepper jack", "mexican blend", "provolone"],
        ["ground beef", "ground turkey", "ground pork"],
        ["sour cream", "greek yogurt"],
        ["heavy cream", "half and half"],
        ["chicken thigh", "chicken breast"],
        ["penne", "rigatoni", "ziti", "macaroni", "rotini", "pasta"],
        ["white rice", "jasmine rice", "basmati rice", "rice"],
        ["black bean", "pinto bean", "kidney bean"],
    ]

    /// An item on the shelves that could stand in for `canonical`, with enough of it.
    static func swap(for canonical: String, need: Double, kind: PantryUnitKind, in items: [PantryItem], amounts: [String: PantryAmount]) -> PantryItem? {
        guard let group = swapGroups.first(where: { $0.contains { canonical == $0 || canonical.hasSuffix(" " + $0) || canonical.contains($0) } }) else { return nil }
        return items.first { item in
            item.canonical != canonical && item.kind == kind
                && group.contains { item.canonical == $0 || item.canonical.hasSuffix(" " + $0) || item.canonical.contains($0) }
                && (amounts[item.id]?.amount ?? 0) >= need
        }
    }
}
