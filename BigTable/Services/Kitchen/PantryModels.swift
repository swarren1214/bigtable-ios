import Foundation

// The pantry, as the kitchen keeps it (see KitchenModels): what the family has, where it's
// kept, the containers they've named, and every change to an amount. Amounts are never stored
// on an item; they're the sum of its change records (PantryLedger), so two phones changing the
// same thing at once both count.

/// What an item is measured in. Each kind has one base unit that amounts are kept in:
/// pounds for weight, cups for volume, and a plain count for everything else.
nonisolated enum PantryUnitKind: String, Codable, Sendable, CaseIterable {
    case weight, volume, count
}

nonisolated enum PantryPlaceKind: String, Codable, Sendable {
    case fridge, freezer, pantry, other

    var symbol: String {
        switch self {
        case .fridge: "refrigerator"
        case .freezer: "snowflake"
        case .pantry: "cabinet"
        case .other: "house"
        }
    }

    /// Fridge blue, freezer indigo, pantry amber, other gray (the canvas designs).
    var colorHex: UInt32 {
        switch self {
        case .fridge: 0x0A7AFF
        case .freezer: 0x5E5CE6
        case .pantry: 0xC77700
        case .other: 0x6E6E73
        }
    }
}

/// Something the family keeps: "Shredded cheddar", "Eggs", "Jasmine rice".
nonisolated struct PantryItem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    /// Lowercased, singular, without brand or prep words (PantryNames.canonical). Recipe
    /// ingredients and receipt lines are matched on it.
    var canonical: String
    var placeID: String
    var kind: PantryUnitKind
    /// How amounts are shown: a measurement value ("lb", "cup", "gal", "each", "dozen", "can").
    var displayUnit: String
    /// "5 lb bag at Costco", learned from receipts.
    var usualBuy: String?
    /// Put it on the grocery list when it'll run out before the next shop.
    var keepStocked: Bool = false
    /// Other names this item has been matched by (receipt lines, what people said).
    var aliases: [String] = []
    var deletedAt: Date?
    var updatedAt: Date
}

/// Where things are kept: Fridge, Freezer, Pantry, and whatever else the family adds (Garage).
nonisolated struct PantryPlace: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var kind: PantryPlaceKind
    var order: Int
    var deletedAt: Date?
    var updatedAt: Date

    static let fridgeID = "fridge"
    static let freezerID = "freezer"
    static let pantryID = "pantry"

    /// Every kitchen starts with these three.
    static var defaults: [PantryPlace] {
        [
            PantryPlace(id: fridgeID, name: "Fridge", kind: .fridge, order: 0, updatedAt: .distantPast),
            PantryPlace(id: freezerID, name: "Freezer", kind: .freezer, order: 1, updatedAt: .distantPast),
            PantryPlace(id: pantryID, name: "Pantry", kind: .pantry, order: 2, updatedAt: .distantPast),
        ]
    }
}

/// A container the family named by talking: "the flour bin", which holds 10 lb. Its item's
/// amount is what's in it; "about a third full" sets it to a third of the capacity.
nonisolated struct PantryContainer: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var placeID: String
    /// What it holds, in the item's base unit (nil until someone says).
    var capacity: Double?
    var itemID: String?
    /// The bulk item it's refilled from (the 10 lb bag of oats in the garage).
    var refillFromItemID: String?
    var deletedAt: Date?
    var updatedAt: Date
}

nonisolated enum PantryChangeKind: String, Codable, Sendable {
    /// Bought or brought in.
    case add
    /// Cooked with, eaten, poured out.
    case use
    /// "I have 4 lb of rice": the amount from now on.
    case set
    /// "The flour bin is a third full": `amount` is 0–1 of the container's capacity.
    case level
}

nonisolated enum PantrySource: String, Codable, Sendable {
    case receipt, checkoff, cooked, voice, check, edit, refill
}

/// One change to one item's amount. Written once and never edited; undo deletes it.
nonisolated struct PantryChange: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var itemID: String
    var kind: PantryChangeKind
    /// In the item's base unit (a fraction for `level`). Nil when it isn't known ("used some").
    var amount: Double?
    var containerID: String?
    var source: PantrySource
    /// What made it: a receipt id, a plan slot key, a grocery item ("listID/itemID").
    var sourceRef: String?
    /// 0–1: how sure this change is. Receipts and voice are sure; cooking is an estimate.
    var confidence: Double
    /// Who made it (a first name), when known.
    var by: String?
    var at: Date
}

/// "Use mozzarella on Pizza Night": for one planned meal, an item that stands in for another.
nonisolated struct PantrySwap: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(slotKey)|\(fromCanonical)" }
    var slotKey: String
    var fromCanonical: String
    var toItemID: String
    var deletedAt: Date?
    var updatedAt: Date
}

/// Everything the pantry keeps, inside the kitchen.
nonisolated struct KitchenPantry: Codable, Hashable, Sendable {
    var items: [String: PantryItem] = [:]
    var places: [String: PantryPlace] = [:]
    var containers: [String: PantryContainer] = [:]
    var changes: [String: PantryChange] = [:]
    var swaps: [String: PantrySwap] = [:]

    var liveItems: [PantryItem] { items.values.filter { $0.deletedAt == nil } }
    var livePlaces: [PantryPlace] {
        var all = Dictionary(uniqueKeysWithValues: PantryPlace.defaults.map { ($0.id, $0) })
        for place in places.values { all[place.id] = place }
        return all.values.filter { $0.deletedAt == nil }.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }
    var liveContainers: [PantryContainer] { containers.values.filter { $0.deletedAt == nil } }
}
