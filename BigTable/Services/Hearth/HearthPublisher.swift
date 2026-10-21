import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What BigTable shares with the other Hearth apps on this device: the planned meals and the
/// grocery list. See `HearthShared.swift`. (The household itself is HearthKit's, in iCloud.)
@MainActor
enum HearthPublisher {
    /// How far back and ahead the shared plan reaches.
    private static let daysBack = 1
    private static let daysAhead = 21
    /// Meals from yesterday through this many days ahead include their recipes and ingredients.
    private static let recipeDaysAhead = 3

    /// The weeks last shared, so the plan can be shared again once recipes load.
    private static var latestWeeks: [String: PlannerResponse] = [:]
    private static var recipeTask: Task<Void, Never>?


    /// Shares the loaded weeks' meals, keeping days already shared that aren't loaded now.
    /// Recipes not loaded yet load in the background, and the plan is shared again with them.
    static func publishPlan(weeks: [String: PlannerResponse], now: Date = .now) {
        guard !ScreenshotMode.isOn else { return }
        latestWeeks = weeks
        let calendar = Calendar.current
        let first = ISODay.string(from: calendar.date(byAdding: .day, value: -daysBack, to: now) ?? now)
        let last = ISODay.string(from: calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now)
        let lastWithRecipes = ISODay.string(from: calendar.date(byAdding: .day, value: recipeDaysAhead, to: now) ?? now)

        var previous: [String: HearthMealPlan.Day] = [:]
        if let existing = Hearth.read(HearthMealPlan.self, from: .bigtable) {
            for day in existing.value.days { previous[day.date] = day }
        }
        var byDate = previous
        var toLoad: [HearthRecipeCache.Key] = []
        for planner in weeks.values {
            for day in DayOfWeek.allCases {
                let date = ISODay.adding(days: day.offset, to: planner.weekStart)
                let withRecipes = date >= first && date <= lastWithRecipes
                var meals: [HearthMealPlan.Meal] = []
                for slot in MealSlotType.allCases {
                    let planned = planner.slot(day, slot)
                    guard var shared = meal(planned, slot: slot, date: date) else { continue }
                    if withRecipes {
                        let keys = recipeKeys(planned)
                        toLoad += keys
                        let earlier = previous[date]?.meals.first { $0.slot == shared.slot }
                        shared.recipes = recipes(keys, for: shared, previously: earlier)
                    }
                    meals.append(shared)
                }
                byDate[date] = HearthMealPlan.Day(date: date, meals: meals)
            }
        }
        let days = byDate.values
            .filter { $0.date >= first && $0.date <= last && !$0.meals.isEmpty }
            .sorted { $0.date < $1.date }
        Hearth.publish(HearthMealPlan(days: days), from: .bigtable)
        loadRecipes(toLoad, now: now)
    }

    /// Shares the grocery list's estimate and how much is left to buy (Suffice shows it as
    /// planned grocery spending). Nil clears it.
    static func publishGroceries(_ list: HearthGroceries.List?) {
        guard !ScreenshotMode.isOn else { return }
        Hearth.publish(HearthGroceries(list: list), from: .bigtable)
    }

    /// Signed out: nothing of this account stays shared.
    static func clear() {
        recipeTask?.cancel()
        recipeTask = nil
        latestWeeks = [:]
        HearthRecipeCache.shared.removeAll()
        Hearth.remove(HearthMealPlan.self, from: .bigtable)
        Hearth.remove(HearthFamily.self, from: .bigtable)
        Hearth.remove(HearthGroceries.self, from: .bigtable)
        Hearth.removePhotos(from: .bigtable, except: [])
    }

    private static func meal(_ slot: PlannerSlot, slot type: MealSlotType, date: String) -> HearthMealPlan.Meal? {
        guard !slot.isEmpty else { return nil }
        let kind: String
        var link = "bigtable://plan"
        if slot.dineOut != nil {
            kind = "dineOut"
        } else if !slot.recipeItems.isEmpty {
            kind = slot.recipeItems.contains { $0.recipeId != nil } ? "recipe" : "custom"
            if let id = slot.recipeItems.first(where: { $0.recipeId != nil })?.recipeId {
                link = "bigtable://recipe/\(id)"
            }
        } else {
            kind = "custom"
        }
        let recipeIDs = slot.recipeItems.compactMap(\.recipeId)
        return HearthMealPlan.Meal(
            slot: type.rawValue,
            title: slot.title,
            kind: kind,
            recipeIDs: recipeIDs.isEmpty ? nil : recipeIDs,
            imageURL: Self.photo(of: slot),
            logoURL: slot.dineOut?.logoUrl.flatMap { $0.isEmpty ? nil : $0 },
            placeName: slot.dineOut?.name,
            notEating: slot.excludedMembers.isEmpty ? nil : slot.excludedMembers,
            link: link,
            recipes: nil
        )
    }

    /// The meal's photo: the main dish's, or the first dish with one.
    private static func photo(of slot: PlannerSlot) -> String? {
        let withPhotos = slot.recipeItems.filter { !($0.imageUrl ?? "").isEmpty }
        return (withPhotos.first { $0.role == .entree } ?? withPhotos.first)?.imageUrl
    }

    // MARK: Recipes

    /// The meal's recipes, at the version planned when there is one.
    private static func recipeKeys(_ slot: PlannerSlot) -> [HearthRecipeCache.Key] {
        var keys: [HearthRecipeCache.Key] = []
        for item in slot.recipeItems {
            guard let id = item.recipeId else { continue }
            let key = HearthRecipeCache.Key(recipeID: id, versionID: item.recipeVersionId)
            if !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// The loaded recipes. Until they've all loaded, what was shared before for the same
    /// recipes stays, so the other apps don't see them disappear and come back.
    private static func recipes(_ keys: [HearthRecipeCache.Key], for meal: HearthMealPlan.Meal, previously earlier: HearthMealPlan.Meal?) -> [HearthMealPlan.Recipe]? {
        guard !keys.isEmpty else { return nil }
        let loaded = keys.compactMap { HearthRecipeCache.shared.recipe(for: $0) }
        if loaded.count < keys.count, let earlier, earlier.recipeIDs == meal.recipeIDs, let kept = earlier.recipes {
            return kept
        }
        return loaded.isEmpty ? nil : loaded
    }

    /// Loads the recipes not loaded yet, then shares the plan again. One load at a time; edits
    /// made meanwhile are picked up when it finishes.
    private static func loadRecipes(_ keys: [HearthRecipeCache.Key], now: Date) {
        guard recipeTask == nil else { return }
        let cache = HearthRecipeCache.shared
        var missing: [HearthRecipeCache.Key] = []
        for key in keys where cache.needsLoad(key, now: now) && !missing.contains(key) {
            missing.append(key)
        }
        guard !missing.isEmpty else { return }
        recipeTask = Task {
            await cache.load(missing)
            guard !Task.isCancelled else { return }
            HearthPublisher.recipeTask = nil
            HearthPublisher.publishPlan(weeks: HearthPublisher.latestWeeks)
        }
    }
}

/// Member photos for the other Hearth apps: downloaded and scaled off the main thread.
nonisolated enum HearthPhotoDownloader {
    /// The longest side of a shared photo, in pixels.
    static let maxSide = 512

    /// The photo at `url` as a JPEG at most 512 px on its longest side, or nil.
    @concurrent static func smallJPEG(from url: URL) async -> Data? {
        let result = try? await URLSession.shared.data(from: url)
        guard let data = result?.0, let http = result?.1 as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return scaledJPEG(data)
    }

    static func scaledJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
