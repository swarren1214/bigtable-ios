import Foundation

/// One receipt line on the Put Away screen: what it is, how much, where it goes.
struct PutAwayLine: Identifiable, Hashable {
    var id: String
    var line: HearthReceiptLine
    /// The pantry item it adds to; nil makes a new one called `name`.
    var itemID: String?
    var name: String
    var quantity: Double?
    var unit: String?
    var placeID: String
    /// Grocery list items it crosses off.
    var listItemIDs: [String]
    /// Why it goes there, or what it's for ("Crossed off your list", "For Chili tomorrow").
    var note: String
    /// The place was chosen from the plan, not habit ("Fridge, not freezer: Chili is tomorrow").
    var placeFromPlan: Bool
}

/// Receipts from Suffice, put away in the pantry.
extension KitchenStore {
    private static let dismissedKey = "pantry.dismissedReceipts"

    /// Grocery receipts from the last 30 days that haven't been put away (or dismissed).
    func pendingReceipts(now: Date = .now) -> [HearthReceipt] {
        _ = pantryRevision  // Dismissing one changes only UserDefaults.
        guard let shared = Hearth.read(HearthReceipts.self, from: .suffice) else { return [] }
        let done = Set(pantry.changes.values.compactMap { change -> String? in
            guard change.source == .receipt, let ref = change.sourceRef else { return nil }
            return ref.split(separator: "/").first.map(String.init)
        })
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        let since = now.addingTimeInterval(-30 * 86_400)
        return shared.value.receipts
            .filter { $0.purchasedAt > since && !done.contains($0.id) && !dismissed.contains($0.id) && $0.lines.contains(where: \.isFood) }
            .sorted { $0.purchasedAt > $1.purchasedAt }
    }

    func dismissReceipt(_ receipt: HearthReceipt) {
        var dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        dismissed.append(receipt.id)
        UserDefaults.standard.set(Array(dismissed.suffix(100)), forKey: Self.dismissedKey)
        pantryChanged()
    }

    /// Each food line matched to an item, the grocery list and a place.
    func putAwayLines(for receipt: HearthReceipt, now: Date = .now) -> [PutAwayLine] {
        let items = pantry.liveItems
        let places = pantry.livePlaces
        let overflow = places.first { $0.kind == .other }
        let list = GroceryStore.shared.allItems.filter { !GroceryStore.shared.isChecked($0) }
        let soon = plannedUses(until: now.addingTimeInterval(3 * 86_400), now: now)
        let today = ISODay.string(from: now)
        let tomorrow = ISODay.string(from: now.addingTimeInterval(86_400))
        var claimed = Set<String>()

        return receipt.lines.enumerated().compactMap { index, line in
            guard line.isFood else { return nil }
            let lookup = line.name.isEmpty ? line.raw : line.name
            let item = PantryNames.match(lookup, in: items) ?? PantryNames.match(line.raw, in: items)
            let canonical = item?.canonical ?? PantryNames.canonical(lookup)
            let matches = list.filter { !claimed.contains($0.id) && PantryNames.score(PantryNames.canonical($0.name), canonical) >= 0.8 }
            for match in matches { claimed.insert(match.id) }

            var place = item?.placeID ?? KitchenStore.defaultPlace(for: canonical, in: pantry)
            var note = matches.isEmpty ? "" : "Crossed off your list"
            var fromPlan = false
            // Meat for the next two days stays in the fridge; later, the freezer.
            let meat = ["chicken", "beef", "pork", "turkey", "sausage", "fish", "salmon", "shrimp", "roast", "steak"]
            if meat.contains(where: { canonical.contains($0) }) {
                let uses = item.flatMap { soon[$0.id] } ?? []
                if let next = uses.first, next.date <= tomorrow {
                    place = PantryPlace.fridgeID
                    fromPlan = true
                    note = "Fridge, not freezer: \(next.mealTitle) is \(next.date == today ? "today" : "tomorrow")"
                } else if item == nil {
                    place = PantryPlace.freezerID
                }
            } else if let uses = item.flatMap({ soon[$0.id] }), let next = uses.first, note.isEmpty {
                note = "For \(next.mealTitle)"
            }
            // Big bags go where the family keeps bulk, when they have somewhere.
            if let overflow, item == nil, Self.isBulk(line) { place = overflow.id }

            return PutAwayLine(
                id: "\(index)", line: line, itemID: item?.id, name: item?.name ?? KitchenStore.displayName(lookup),
                quantity: line.quantity, unit: line.unit, placeID: place, listItemIDs: matches.map(\.id),
                note: note, placeFromPlan: fromPlan
            )
        }
    }

    static func isBulk(_ line: HearthReceiptLine) -> Bool {
        guard let quantity = line.quantity else { return false }
        switch PantryUnits.normalized(line.unit) {
        case "lb": return quantity >= 10
        case "oz": return quantity >= 160
        default: return false
        }
    }

    /// Adds every line to the pantry, crosses off the list, and remembers each place.
    func putAway(_ receipt: HearthReceipt, lines: [PutAwayLine]) {
        var bought: [String] = []
        for line in lines {
            var item: PantryItem
            if let id = line.itemID, let existing = pantry.items[id] {
                item = existing
            } else {
                item = pantryItem(named: line.name, unit: line.unit, placeID: line.placeID)
            }
            // A move on the Put Away screen is where it goes from now on.
            let alias = line.line.raw.lowercased()
            if item.placeID != line.placeID || !item.aliases.contains(alias) {
                item.placeID = line.placeID
                if !item.aliases.contains(alias) { item.aliases = Array((item.aliases + [alias]).suffix(12)) }
                if let quantity = line.quantity {
                    item.usualBuy = "\(Ingredients.formatAmount(quantity))\(line.unit.map { " " + $0 } ?? "") at \(receipt.store)"
                }
                item.updatedAt = .now
                put(pantryItem: item)
            }
            let base = line.quantity.flatMap { PantryUnits.toBase($0, unit: line.unit, for: item) }
            // A check-off at the store in the last two days was a guess at the same thing.
            let recent = receipt.purchasedAt.addingTimeInterval(-2 * 86_400)
            for change in pantry.changes.values where change.itemID == item.id && change.source == .checkoff && change.at > recent {
                removePantryChange(change.id)
            }
            record(.add, base, of: item, source: .receipt, ref: "\(receipt.id)/\(line.id)", confidence: base == nil ? 0.6 : 0.95, at: receipt.purchasedAt)
            bought += line.listItemIDs
        }
        GroceryStore.shared.markBought(bought)
        pantryChanged()
    }

    /// Undoes a put-away.
    func undoPutAway(_ receipt: HearthReceipt) {
        for change in pantry.changes.values where change.source == .receipt && (change.sourceRef ?? "").hasPrefix(receipt.id + "/") {
            removePantryChange(change.id)
        }
        pantryChanged()
    }
}
