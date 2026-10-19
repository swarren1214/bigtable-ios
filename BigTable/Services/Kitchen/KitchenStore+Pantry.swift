import Foundation

/// What the pantry screens show at one moment: items with their amounts, places, what runs
/// out before the next shop, and what to use up. Built from the kitchen on demand.
struct PantrySnapshot {
    struct Row: Identifiable, Hashable {
        var item: PantryItem
        var amount: PantryAmount
        var place: PantryPlace?
        var container: PantryContainer?
        var shortfall: PantryLedger.Shortfall?
        /// Planned meals still to cook that use it ("Saved for Chili Thursday").
        var savedFor: [PantryLedger.PlannedUse]
        var daysLeft: Int?
        var onList: Bool
        var id: String { item.id }
    }

    var rows: [Row]
    var places: [PantryPlace]
    var nextShop: Date

    var runningOut: [Row] {
        rows.filter { $0.shortfall != nil }
            .sorted { ($0.shortfall?.date ?? "", $0.shortfall?.isGuess == true ? 1 : 0) < ($1.shortfall?.date ?? "", $1.shortfall?.isGuess == true ? 1 : 0) }
    }

    var useItUp: [Row] {
        rows.filter { $0.daysLeft != nil }.sorted { ($0.daysLeft ?? 0) < ($1.daysLeft ?? 0) }
    }

    func rows(in placeID: String) -> [Row] {
        rows.filter { $0.item.placeID == placeID && !($0.amount.isOut && $0.amount.lastSure == nil && $0.amount.lastAdded == nil) }
            .sorted { lhs, rhs in
                let l = lhs.shortfall != nil ? 0 : (lhs.savedFor.isEmpty ? 2 : 1)
                let r = rhs.shortfall != nil ? 0 : (rhs.savedFor.isEmpty ? 2 : 1)
                return l != r ? l < r : lhs.item.name.localizedCaseInsensitiveCompare(rhs.item.name) == .orderedAscending
            }
    }

    func count(in placeID: String) -> Int { rows(in: placeID).count }
    var total: Int { rows.filter { !$0.amount.isOut }.count }
    func row(_ id: String) -> Row? { rows.first { $0.id == id } }
}

/// How the quick check answers.
enum PantryCheckAnswer {
    case plenty, low, out
}

/// The pantry's calls, for screens and Ask BigTable. Everything is written as kitchen records
/// (KitchenStore), so it syncs to the household through iCloud.
extension KitchenStore {
    var pantry: KitchenPantry { state.pantry ?? KitchenPantry() }

    // MARK: - Reading

    func pantrySnapshot(now: Date = .now) -> PantrySnapshot {
        let pantry = self.pantry
        let amounts = PantryLedger.amounts(pantry)
        let places = pantry.livePlaces
        let placeByID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        let shop = PantryLedger.nextShop(pantry, now: now)
        let uses = plannedUses(until: shop, now: now)
        let listNames = Set(GroceryStore.shared.allItems.filter { !GroceryStore.shared.isChecked($0) }.map { PantryNames.canonical($0.name) })
        let rows = pantry.liveItems.map { item -> PantrySnapshot.Row in
            let amount = amounts[item.id] ?? .unknown
            let mine = uses[item.id] ?? []
            var shortfall = PantryLedger.shortfall(item: item, amount: amount, uses: mine)
            if shortfall == nil, mine.isEmpty { shortfall = PantryLedger.outByRate(item: item, amount: amount, before: shop) }
            let container = pantry.liveContainers.first { $0.itemID == item.id }
            return PantrySnapshot.Row(
                item: item, amount: amount, place: placeByID[item.placeID], container: container,
                shortfall: shortfall, savedFor: mine,
                daysLeft: PantryLedger.daysLeft(item: item, place: placeByID[item.placeID], amount: amount, now: now),
                onList: listNames.contains { PantryNames.score($0, item.canonical) >= 0.8 }
            )
        }
        return PantrySnapshot(rows: rows, places: places, nextShop: shop)
    }

    /// Each item's planned uses from today until the next shop, in order (meals not yet cooked).
    func plannedUses(until shop: Date, now: Date = .now) -> [String: [PantryLedger.PlannedUse]] {
        let today = ISODay.string(from: now)
        let last = ISODay.string(from: shop.addingTimeInterval(-86_400))
        guard last >= today else { return [:] }
        let items = pantry.liveItems
        let swaps = pantry.swaps.values.filter { $0.deletedAt == nil }
        let householdSize = max(1, AppModel.shared.householdSize)
        var result: [String: [PantryLedger.PlannedUse]] = [:]
        for planned in plannedSlots(from: today, to: last) where !planned.value.completed {
            let week = ISODay.date(from: planned.date).map { ISODay.weekStart(containing: $0) } ?? planned.date
            let key = KitchenSlot.key(weekStart: week, day: planned.day, slot: planned.slot)
            let eaters = Double(max(1, householdSize - planned.value.excludedMembers.count))
            for meal in planned.value.recipeItems {
                guard let id = meal.recipeId, let recipe = state.recipes[id]?.detail else { continue }
                let scale = eaters / max(recipe.baseServings, 1)
                for ingredient in recipe.ingredients {
                    let canonical = PantryNames.canonical(ingredient.name)
                    var item = PantryNames.match(ingredient.name, in: items)
                    if let swap = swaps.first(where: { $0.slotKey == key && $0.fromCanonical == canonical }),
                       let swapped = items.first(where: { $0.id == swap.toItemID }) {
                        item = swapped
                    }
                    guard let item else { continue }
                    let amount = ingredient.amount.flatMap { PantryUnits.toBase($0 * scale, unit: ingredient.measurementType, for: item) }
                    result[item.id, default: []].append(PantryLedger.PlannedUse(
                        date: planned.date, slot: planned.slot, slotKey: key, mealTitle: recipe.title, amount: amount
                    ))
                }
            }
        }
        return result
    }

    // MARK: - Items

    /// The item called `name`, made if it's new (in `placeID`, measured like `unit`).
    @discardableResult
    func pantryItem(named name: String, unit: String? = nil, placeID: String? = nil) -> PantryItem {
        if let existing = PantryNames.match(name, in: pantry.liveItems) { return existing }
        let canonical = PantryNames.canonical(name)
        let kind = PantryUnits.kind(of: unit ?? "")
        let item = PantryItem(
            id: UUID().uuidString.lowercased(),
            name: Self.displayName(name),
            canonical: canonical.isEmpty ? name.lowercased() : canonical,
            placeID: placeID ?? Self.defaultPlace(for: canonical, in: pantry),
            kind: kind,
            displayUnit: PantryUnits.displayUnit(for: unit, kind: kind),
            updatedAt: .now
        )
        put(pantryItem: item)
        return item
    }

    func update(_ item: PantryItem) {
        var item = item
        item.updatedAt = .now
        put(pantryItem: item)
        pantryChanged()
    }

    func removeFromPantry(_ item: PantryItem) {
        var item = item
        item.deletedAt = .now
        update(item)
    }

    func addPantryPlace(named name: String) -> PantryPlace {
        let order = (pantry.livePlaces.map(\.order).max() ?? 2) + 1
        let place = PantryPlace(id: UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: .other, order: order, updatedAt: .now)
        put(pantryPlace: place)
        pantryChanged()
        return place
    }

    // MARK: - Changing amounts

    @discardableResult
    func record(_ kind: PantryChangeKind, _ amount: Double?, of item: PantryItem, source: PantrySource, ref: String? = nil, confidence: Double, container: PantryContainer? = nil, at: Date = .now) -> PantryChange {
        let change = PantryChange(
            id: UUID().uuidString.lowercased(), itemID: item.id, kind: kind, amount: amount,
            containerID: container?.id, source: source, sourceRef: ref, confidence: confidence, by: nil, at: at
        )
        put(pantryChange: change)
        return change
    }

    /// "I have 4 lb of rice" or an edit on the item screen.
    func setAmount(_ base: Double, of item: PantryItem, source: PantrySource = .edit) {
        record(.set, max(0, base), of: item, source: source, confidence: 1)
        pantryChanged()
    }

    /// "The flour bin is about a third full."
    func setLevel(_ level: Double, of container: PantryContainer, source: PantrySource = .voice) {
        guard let id = container.itemID, let item = pantry.items[id] else { return }
        record(.level, min(1, max(0, level)), of: item, source: source, confidence: 1, container: container)
        pantryChanged()
    }

    /// Filled a container from its bulk item: what went in comes out of the bag.
    func refill(_ container: PantryContainer) {
        guard let id = container.itemID, let item = pantry.items[id], let capacity = container.capacity else { return }
        let amounts = PantryLedger.amounts(pantry)
        let inside = amounts[id]?.amount ?? 0
        let moved = max(0, capacity - inside)
        record(.level, 1, of: item, source: .refill, confidence: 1, container: container)
        if let bulkID = container.refillFromItemID, let bulk = pantry.items[bulkID], moved > 0 {
            record(.use, moved, of: bulk, source: .refill, ref: container.id, confidence: 1)
        }
        pantryChanged()
    }

    func saveContainer(_ container: PantryContainer) {
        var container = container
        container.updatedAt = .now
        put(pantryContainer: container)
        pantryChanged()
    }

    /// The container called `name` ("the flour bin"), when there is one.
    func pantryContainer(named name: String) -> PantryContainer? {
        let key = PantryNames.canonical(name.replacingOccurrences(of: "the ", with: ""))
        return pantry.liveContainers.first { PantryNames.score(PantryNames.canonical($0.name), key) >= 0.8 }
    }

    // MARK: - Quick check

    /// Items worth asking about: least sure first, those the plan uses ahead of the rest.
    func pantryCheckItems(limit: Int = 6) -> [PantrySnapshot.Row] {
        let snapshot = pantrySnapshot()
        return snapshot.rows
            .filter { $0.amount.isUnsure && ($0.amount.lastAdded != nil || $0.amount.lastSure != nil) && !$0.amount.isOut }
            .sorted { lhs, rhs in
                let l = (lhs.savedFor.isEmpty ? 1 : 0, lhs.amount.confidence)
                let r = (rhs.savedFor.isEmpty ? 1 : 0, rhs.amount.confidence)
                return l < r
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Answers one card. Low and Out also put it on the grocery list.
    func answerCheck(_ answer: PantryCheckAnswer, for row: PantrySnapshot.Row) async {
        let full = max(row.amount.full, row.amount.amount)
        switch answer {
        case .plenty:
            record(.set, max(row.amount.amount, full * 0.75), of: row.item, source: .check, confidence: 0.75)
        case .low:
            record(.set, full * 0.2, of: row.item, source: .check, confidence: 0.8)
            await addToGroceryList(row.item)
        case .out:
            record(.set, 0, of: row.item, source: .check, confidence: 1)
            await addToGroceryList(row.item)
        }
        pantryChanged()
    }

    // MARK: - Grocery list

    /// Puts an item on the active list (its usual buy when known), unless it's there already.
    func addToGroceryList(_ item: PantryItem, quantity: String? = nil) async {
        let store = GroceryStore.shared
        if !store.hasLoaded { await store.load() }
        let key = item.canonical
        if store.allItems.contains(where: { !store.isChecked($0) && PantryNames.score(PantryNames.canonical($0.name), key) >= 0.8 }) { return }
        store.addItem(name: item.name, quantity: quantity ?? item.usualBuy ?? "1", to: PantryGrocery.section(for: item.canonical))
    }

    /// A grocery item was checked off (or unchecked): it came home, at the list's amount.
    func groceryChecked(_ grocery: GroceryItem, listID: String?, checked: Bool) {
        let ref = "\(listID ?? "list")/\(grocery.id)"
        if checked {
            guard !pantry.changes.values.contains(where: { $0.sourceRef == ref }) else { return }
            let parsed = PantryGrocery.amount(of: grocery)
            let item = pantryItem(named: grocery.name, unit: parsed.unit)
            let base = parsed.amount.flatMap { PantryUnits.toBase($0, unit: parsed.unit, for: item) }
            record(.add, base, of: item, source: .checkoff, ref: ref, confidence: base == nil ? 0.4 : 0.7)
        } else {
            for change in pantry.changes.values where change.sourceRef == ref { removePantryChange(change.id) }
        }
        pantryChanged()
    }

    // MARK: - Cooking

    /// A meal was marked cooked (or unmarked): its ingredients come off the shelves, scaled to
    /// who ate, or go back.
    func mealCooked(_ slot: PlannerSlot, key: String, completed: Bool) {
        let ref = "slot/" + key
        if !completed {
            for change in pantry.changes.values where change.sourceRef == ref { removePantryChange(change.id) }
            pantryChanged()
            return
        }
        guard !pantry.changes.values.contains(where: { $0.sourceRef == ref }) else { return }
        let items = pantry.liveItems
        let swaps = pantry.swaps.values.filter { $0.slotKey == key && $0.deletedAt == nil }
        let eaters = Double(max(1, max(1, AppModel.shared.householdSize) - slot.excludedMembers.count))
        for meal in slot.recipeItems {
            guard let id = meal.recipeId, let recipe = state.recipes[id]?.detail else { continue }
            let scale = eaters / max(recipe.baseServings, 1)
            for ingredient in recipe.ingredients {
                let canonical = PantryNames.canonical(ingredient.name)
                var item = PantryNames.match(ingredient.name, in: items)
                if let swap = swaps.first(where: { $0.fromCanonical == canonical }), let swapped = items.first(where: { $0.id == swap.toItemID }) {
                    item = swapped
                }
                guard let item else { continue }
                let amount = ingredient.amount.flatMap { PantryUnits.toBase($0 * scale, unit: ingredient.measurementType, for: item) }
                record(.use, amount, of: item, source: .cooked, ref: ref, confidence: 0.6)
            }
        }
        pantryChanged()
    }

    // MARK: - Swaps

    func setSwap(from canonical: String, to item: PantryItem, slotKey: String, on: Bool) {
        var swap = PantrySwap(slotKey: slotKey, fromCanonical: canonical, toItemID: item.id, deletedAt: on ? nil : .now, updatedAt: .now)
        if !on, let existing = pantry.swaps[swap.id] { swap.toItemID = existing.toItemID }
        put(pantrySwap: swap)
        pantryChanged()
    }

    func swap(for canonical: String, slotKey: String) -> PantrySwap? {
        pantry.swaps["\(slotKey)|\(canonical)"].flatMap { $0.deletedAt == nil ? $0 : nil }
    }

    // MARK: - Compaction

    /// Once a month, the owner's phone folds changes older than 60 days into one set per item,
    /// so the zone stays small. The amounts come out the same.
    func compactPantryIfDue(now: Date = .now) {
        guard location == .personal else { return }
        let key = "pantry.compactedAt"
        let last = UserDefaults.standard.double(forKey: key)
        guard now.timeIntervalSince1970 - last > 30 * 86_400 else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key)
        let cutoff = now.addingTimeInterval(-60 * 86_400)
        let old = pantry.changes.values.filter { $0.at < cutoff }
        guard old.count > 50 else { return }
        var folded = KitchenPantry()
        folded.containers = pantry.containers
        for change in old { folded.changes[change.id] = change }
        let amounts = PantryLedger.amounts(folded)
        for (itemID, amount) in amounts {
            guard let item = pantry.items[itemID] else { continue }
            record(.set, amount.amount, of: item, source: .edit, ref: "compacted", confidence: amount.confidence, at: cutoff.addingTimeInterval(-1))
        }
        for change in old { removePantryChange(change.id) }
    }

    // MARK: - Helpers

    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// Where something new goes: frozen things in the freezer, fresh things in the fridge,
    /// the rest in the pantry.
    static func defaultPlace(for canonical: String, in pantry: KitchenPantry) -> String {
        let frozen = ["frozen", "frz", "ice cream", "popsicle"]
        if frozen.contains(where: { canonical.contains($0) }) { return PantryPlace.freezerID }
        let cold = [
            "milk", "cream", "cheese", "cheddar", "mozzarella", "parmesan", "yogurt", "butter", "egg", "chicken", "beef",
            "pork", "turkey", "sausage", "bacon", "ham", "fish", "salmon", "shrimp", "lettuce", "spinach", "berry",
            "pepper", "carrot", "celery", "cucumber", "tortilla", "hummus", "juice", "cilantro", "parsley", "broccoli",
        ]
        if cold.contains(where: { canonical.contains($0) }) { return PantryPlace.fridgeID }
        return PantryPlace.pantryID
    }
}

/// Reading grocery items and choosing their aisle.
enum PantryGrocery {
    /// "2 gal", "3 lb bag", "40", "2 packs of 30" → an amount and unit.
    static func amount(of grocery: GroceryItem) -> (amount: Double?, unit: String?) {
        let parsed = Ingredients.parseLine(grocery.quantity + " " + grocery.name)
        if let amount = parsed.amount {
            return (amount, parsed.measurementType)
        }
        return (nil, nil)
    }

    static func section(for canonical: String) -> String {
        let rules: [(String, [String])] = [
            ("Produce", ["onion", "garlic", "potato", "carrot", "pepper", "tomato", "spinach", "lettuce", "lemon", "lime", "apple", "banana", "avocado", "broccoli", "berry", "celery", "cucumber", "cilantro"]),
            ("Meat", ["chicken", "beef", "pork", "turkey", "salmon", "fish", "shrimp", "sausage", "bacon", "ham", "roast"]),
            ("Dairy", ["milk", "cream", "cheese", "cheddar", "mozzarella", "yogurt", "butter", "egg"]),
            ("Frozen", ["frozen", "ice cream"]),
            ("Bakery", ["bread", "bun", "roll", "bagel", "tortilla"]),
            ("Beverages", ["juice", "soda", "water", "coffee", "tea"]),
        ]
        return rules.first { rule in rule.1.contains(where: { canonical.contains($0) }) }?.0 ?? "Pantry"
    }
}
