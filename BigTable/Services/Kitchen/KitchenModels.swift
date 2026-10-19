import Foundation

// BigTable's private data, as the kitchen keeps it: in the family's iCloud (the Kitchen zone),
// with a copy on the device. Each value is one CloudKit record; the newest `updatedAt` wins.

/// A recipe the family wrote (or saved from a link, a scan or a photo). Published recipes also
/// have a copy on the server under the same id.
nonisolated struct KitchenRecipe: Codable, Hashable, Sendable {
    /// `imageUrl` is stored as an https URL or `kitchen-photo:<file>` (see KitchenPhotos).
    var detail: RecipeDetail
    var deletedAt: Date?
    var updatedAt: Date
}

/// One meal slot in one week.
nonisolated struct KitchenSlot: Codable, Hashable, Sendable {
    var weekStart: String
    var day: DayOfWeek
    var slot: MealSlotType
    var value: PlannerSlot
    var updatedAt: Date

    var key: String { KitchenSlot.key(weekStart: weekStart, day: day, slot: slot) }

    static func key(weekStart: String, day: DayOfWeek, slot: MealSlotType) -> String {
        "\(weekStart)-\(day.rawValue)-\(slot.rawValue)"
    }
}

nonisolated struct KitchenGrocery: Codable, Hashable, Sendable {
    var snapshot: GrocerySnapshot
    var updatedAt: Date
}

nonisolated struct KitchenTag: Codable, Hashable, Sendable {
    var tag: CustomTag
    var updatedAt: Date
}

/// Kitchen-wide settings: which grocery list is the current one.
nonisolated struct KitchenSettings: Codable, Hashable, Sendable {
    var activeGroceryID: String?
    var updatedAt: Date = .distantPast
    /// When the family's data moved here from the server (once, from any device).
    var movedAt: Date? = nil
}

/// Everything in one kitchen, as saved on the device.
nonisolated struct KitchenState: Codable, Hashable, Sendable {
    var recipes: [String: KitchenRecipe] = [:]
    var slots: [String: KitchenSlot] = [:]
    var groceries: [String: KitchenGrocery] = [:]
    var tags: [String: KitchenTag] = [:]
    var settings = KitchenSettings()
    /// The pantry (PantryModels). Optional so kitchens saved before it existed still load.
    var pantry: KitchenPantry? = nil

    var isEmpty: Bool { recipes.isEmpty && slots.isEmpty && groceries.isEmpty && tags.isEmpty }
}

/// Recipe photos the family took or picked, kept on the device and in iCloud (never uploaded
/// to the server unless the recipe is published).
nonisolated enum KitchenPhotos {
    static let scheme = "kitchen-photo:"

    /// In the Hearth app group, so Caloma and Sated can show a planned meal's photo.
    static var folder: URL {
        let base = Hearth.directory ?? URL.applicationSupportDirectory
        let url = base.appending(path: "kitchen-photos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(named name: String) -> URL {
        folder.appending(path: name, directoryHint: .notDirectory)
    }

    /// Saves photo bytes under a name made from their content, and returns the stored value.
    static func save(_ data: Data, ext: String = "jpg") -> String? {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let name = "recipe-\(String(hash, radix: 16)).\(ext)"
        let url = url(named: name)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            guard (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return nil }
        }
        return scheme + name
    }

    /// The file name in a stored value, or nil for an https URL.
    static func name(in stored: String?) -> String? {
        guard let stored, stored.hasPrefix(scheme) else { return nil }
        let name = String(stored.dropFirst(scheme.count))
        return name.isEmpty || name.contains("/") ? nil : name
    }

    /// What screens show: a file URL for kitchen photos, the URL itself otherwise.
    static func display(_ stored: String?) -> String? {
        guard let stored else { return nil }
        if let name = name(in: stored) { return url(named: name).absoluteString }
        return stored
    }

    /// Back from what a screen shows to what's stored.
    static func stored(_ display: String?) -> String? {
        guard let display else { return nil }
        let prefix = folder.absoluteString
        if display.hasPrefix(prefix) { return scheme + String(display.dropFirst(prefix.count)) }
        return display
    }

    static func data(for stored: String?) -> Data? {
        guard let name = name(in: stored) else { return nil }
        return try? Data(contentsOf: url(named: name))
    }

    /// Deletes photos no recipe uses.
    static func clean(keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: url(named: file))
        }
    }
}
