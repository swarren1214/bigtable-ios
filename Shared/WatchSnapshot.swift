import Foundation

// What the iPhone sends the Apple Watch, and what the watch sends back. Compiled into the iPhone
// app, the watch app and the watch's complications (the `Shared` folder is in all three targets).
//
// The phone owns the data (the kitchen in iCloud). It sends a fresh `WatchSnapshot` whenever the
// plan or the grocery list changes (WatchConnectivity's application context: only the newest one
// is delivered). The watch sends small messages back: a grocery check-off (queued, so it arrives
// even when the phone is away) and what was said to Tell the Pantry (live, with a reply).

/// Everything the watch shows: the next meals with their steps, and the current grocery list.
nonisolated struct WatchSnapshot: Codable, Hashable, Sendable {
    var generatedAt: Date
    /// Today's and tomorrow's planned meals, in order.
    var meals: [WatchMeal]
    var grocery: WatchGrocery?

    static let empty = WatchSnapshot(generatedAt: .distantPast, meals: [], grocery: nil)

    /// The meal the watch leads with: the first one today that hasn't finished (still before its
    /// time, or within two hours after) and isn't marked cooked; otherwise tomorrow's first.
    func nextMeal(now: Date = .now) -> WatchMeal? {
        meals.first { !$0.completed && $0.startsAt.addingTimeInterval(2 * 3600) > now }
    }

    /// The meals after `meal` (for "Tomorrow" under tonight's card).
    func meals(after meal: WatchMeal) -> [WatchMeal] {
        guard let index = meals.firstIndex(of: meal) else { return [] }
        return Array(meals.dropFirst(index + 1))
    }
}

nonisolated struct WatchMeal: Codable, Hashable, Sendable, Identifiable {
    /// "2026-10-21-dinner".
    var id: String
    /// "breakfast", "lunch" or "dinner".
    var slot: String
    /// When the family eats it (the household's meal times).
    var startsAt: Date
    /// "Chickpea Fajitas + Rice", "Leftovers", "Dinner at Café Rio".
    var title: String
    var servings: Int?
    /// Prep and cook time of the longest recipe in the meal.
    var minutes: Int?
    var recipes: [WatchRecipe]
    var completed: Bool

    var slotLabel: String { slot.prefix(1).uppercased() + slot.dropFirst() }
    var isToday: Bool { Calendar.current.isDateInToday(startsAt) }
    /// When to start cooking to eat on time.
    var startCookingAt: Date? { minutes.map { startsAt.addingTimeInterval(-Double($0) * 60) } }
    /// The recipes that have steps to cook from.
    var cookable: [WatchRecipe] { recipes.filter { !$0.steps.isEmpty } }
}

nonisolated struct WatchRecipe: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var steps: [WatchStep]
}

nonisolated struct WatchStep: Codable, Hashable, Sendable {
    var text: String
    /// A time the step names ("simmer 15 minutes"), for its timer button.
    var timerSeconds: Int?
}

nonisolated struct WatchGrocery: Codable, Hashable, Sendable {
    var id: String
    var sections: [WatchGrocerySection]
    var checks: [String: Bool]

    var allItems: [WatchGroceryItem] { sections.flatMap(\.items) }
    var remaining: Int { allItems.filter { checks[$0.id] != true }.count }
    var total: Int { allItems.count }
    func isChecked(_ item: WatchGroceryItem) -> Bool { checks[item.id] == true }
}

nonisolated struct WatchGrocerySection: Codable, Hashable, Sendable, Identifiable {
    var name: String
    /// An SF Symbol.
    var icon: String
    var items: [WatchGroceryItem]
    var id: String { name }
}

nonisolated struct WatchGroceryItem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var quantity: String
    /// "For Borsch".
    var note: String?
}

/// One line of what Tell the Pantry did: "Milk", "2 gal", "Fridge".
nonisolated struct WatchPantryLine: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var change: String
    var detail: String
}

/// The keys of the dictionaries the two sides send (WatchConnectivity only carries property lists).
nonisolated enum WatchKeys {
    static let snapshot = "snapshot"
    static let kind = "kind"
    // Kinds of message from the watch.
    static let refresh = "refresh"
    static let check = "check"
    static let pantry = "pantry"
    // Fields.
    static let itemID = "itemID"
    static let listID = "listID"
    static let checked = "checked"
    static let text = "text"
    static let lines = "lines"
    static let error = "error"
}

/// The app group the watch app and its complications share (on the watch).
nonisolated enum WatchShared {
    static let appGroup = "group.com.stephenwarren.bigtable"
    static let snapshotFile = "watch-snapshot.json"
    /// The running cooking timer, for the complication: its end and what it's for.
    static let timerEndKey = "watch.timer.end"
    static let timerLabelKey = "watch.timer.label"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static func loadSnapshot() -> WatchSnapshot? {
        guard let url = container?.appending(path: snapshotFile),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }

    static func save(_ snapshot: WatchSnapshot) {
        guard let url = container?.appending(path: snapshotFile),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
}

/// Finds the time a recipe step names, for a timer: "simmer for 15 minutes" → 900,
/// "bake 25–30 min" → 1500 (the shorter, so it's checked in time), "1 hour" → 3600,
/// "1 1/2 hours" → 5400. Nil when the step names no time.
nonisolated enum StepTimer {
    static func seconds(in text: String) -> Int? {
        let pattern = #"(\d+(?:\.\d+)?)(?:\s+(\d)/(\d))?\s*(?:(?:-|–|to)\s*\d+(?:\.\d+)?\s*)?(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 4), in: text),
              var value = Double(text[numberRange]) else { return nil }
        if let topRange = Range(match.range(at: 2), in: text), let bottomRange = Range(match.range(at: 3), in: text),
           let top = Double(text[topRange]), let bottom = Double(text[bottomRange]), bottom > 0 {
            value += top / bottom
        }
        let unit = text[unitRange].lowercased()
        let factor: Double = unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1
        let seconds = Int(value * factor)
        return seconds > 0 && seconds <= 12 * 3600 ? seconds : nil
    }
}
