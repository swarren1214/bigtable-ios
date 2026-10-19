// HearthReceipts.swift — grocery receipts Suffice has read, shared with BigTable so the family
// can put a shop away in the pantry. Only receipts whose charge is groceries are shared, and
// only on this device (the Hearth app group); nothing goes through a server.
//
// The same file is in Suffice (which publishes) and BigTable (which reads). Keep the two
// copies the same.

import Foundation

nonisolated struct HearthReceipts: HearthPublication {
    static let kind = "receipts"
    static let version = 1

    /// The last 30 days, newest first.
    var receipts: [HearthReceipt]
}

nonisolated struct HearthReceipt: Codable, Hashable, Sendable, Identifiable {
    /// Suffice's transaction id: stable, so a receipt is put away once.
    var id: String
    var store: String
    var purchasedAt: Date
    /// The charge, in dollars.
    var total: Double?
    /// "photo" or "email".
    var source: String
    var lines: [HearthReceiptLine]
}

nonisolated struct HearthReceiptLine: Codable, Hashable, Sendable {
    /// As printed: "KS ORG EGGS 24CT".
    var raw: String
    var price: Double?
    /// A plain name: "Eggs".
    var name: String
    /// How much in all, when the receipt says ("24CT" × 2 = 48), in `unit`.
    var quantity: Double?
    /// "each", "lb", "oz", "gal", "can"…
    var unit: String?
    /// False for paper towels, batteries and the like.
    var isFood: Bool
}
