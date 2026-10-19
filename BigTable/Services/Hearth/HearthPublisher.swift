import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What BigTable shares with the other Hearth apps on this device: the planned meals and the
/// household. See `HearthShared.swift`.
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

    /// The household last shared, so it can be shared again once photos download.
    private static var latestFamily: (me: MeResponse, householdName: String?, userID: String?)?
    private static var photoTask: Task<Void, Never>?
    /// Avatar URLs that couldn't be downloaded this launch (not tried again until next launch).
    private static var failedPhotoURLs: Set<String> = []
    /// Shared photos by member id: [the avatar URL it came from, the shared file name]. Kept
    /// across launches so unchanged photos aren't downloaded again.
    private static let photoSourcesKey = "hearth.bigtable.photoSources"

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

    /// Shares the household: its name, people, their photos, who "me" is, and dietary
    /// restrictions. Photos not downloaded yet download in the background, and the household
    /// is shared again with them.
    static func publishFamily(_ me: MeResponse, householdName: String?, userID: String?) {
        guard !ScreenshotMode.isOn else { return }
        latestFamily = (me, householdName, userID)
        let previousPhotos = sharedPhotoNames()
        let sources = photoSources
        var pending: [(memberID: String, url: String)] = []
        var members: [HearthFamily.Member] = []
        for (index, member) in me.householdMembers.enumerated() {
            let id = member.id ?? "member-\(index)"
            var photo: String?
            if let url = ProfileAvatar.url(for: member.avatarUrl) {
                if let source = sources[id], source.count == 2, source[0] == url, photoExists(source[1]) {
                    photo = source[1]
                } else if !failedPhotoURLs.contains(url) {
                    pending.append((id, url))
                    // The photo shared before stays until the new one has downloaded.
                    photo = previousPhotos[id]
                }
            }
            members.append(HearthFamily.Member(
                id: id,
                name: member.name,
                role: nil,
                colorHex: nil,
                birthday: member.dateOfBirth,
                likes: member.likes.isEmpty ? nil : member.likes,
                dislikes: member.dislikes.isEmpty ? nil : member.dislikes,
                photo: photo
            ))
        }
        let restrictions = me.dietaryRestrictions.map(\.value).filter { !$0.isEmpty }
        Hearth.publish(
            HearthFamily(
                name: householdName,
                members: members,
                dietaryRestrictions: restrictions.isEmpty ? nil : restrictions,
                me: myMemberID(in: me, members: members, userID: userID)
            ),
            from: .bigtable
        )
        let inUse = Set(members.compactMap(\.photo))
        Hearth.removePhotos(from: .bigtable, except: inUse)
        let pendingIDs = Set(pending.map { $0.memberID })
        let kept = photoSources.filter { entry in inUse.contains(entry.value.last ?? "") || pendingIDs.contains(entry.key) }
        if kept != photoSources { photoSources = kept }
        loadPhotos(pending)
    }

    /// The member who is the signed-in person: the one linked to their account, or (for the
    /// organizer, whose own row isn't linked) the one named as them, else the first person.
    private static func myMemberID(in me: MeResponse, members: [HearthFamily.Member], userID: String?) -> String? {
        let people = me.householdMembers
        if let userID, let index = people.firstIndex(where: { $0.linkedProfileId?.trimmingCharacters(in: .whitespaces) == userID }) {
            return members[index].id
        }
        guard (me.membership?.role ?? .organizer) == .organizer else { return nil }
        let unlinked = people.indices.filter { (people[$0].linkedProfileId ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if let mine = me.myMember?.name, !mine.trimmingCharacters(in: .whitespaces).isEmpty,
           let index = unlinked.first(where: { HouseholdDraft.sameName(people[$0].name, mine) }) {
            return members[index].id
        }
        return unlinked.first.map { members[$0].id }
    }

    /// Signed out: nothing of this account stays shared.
    static func clear() {
        recipeTask?.cancel()
        recipeTask = nil
        latestWeeks = [:]
        HearthRecipeCache.shared.removeAll()
        photoTask?.cancel()
        photoTask = nil
        latestFamily = nil
        failedPhotoURLs = []
        UserDefaults.standard.removeObject(forKey: photoSourcesKey)
        Hearth.remove(HearthMealPlan.self, from: .bigtable)
        Hearth.remove(HearthFamily.self, from: .bigtable)
        Hearth.remove(HearthGroceries.self, from: .bigtable)
        Hearth.removePhotos(from: .bigtable, except: [])
    }

    // MARK: Photos

    private static var photoSources: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: photoSourcesKey) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: photoSourcesKey) }
    }

    /// The photo file names BigTable shared last time, by member id.
    private static func sharedPhotoNames() -> [String: String] {
        var names: [String: String] = [:]
        for member in Hearth.read(HearthFamily.self, from: .bigtable)?.value.members ?? [] {
            if let photo = member.photo { names[member.id] = photo }
        }
        return names
    }

    private static func photoExists(_ name: String) -> Bool {
        guard !name.contains("/"), let folder = Hearth.photosDirectory else { return false }
        return FileManager.default.fileExists(atPath: folder.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false))
    }

    /// Downloads the members' photos, one at a time, then shares the household again. Changes
    /// made meanwhile are picked up when it finishes.
    private static func loadPhotos(_ pending: [(memberID: String, url: String)]) {
        guard photoTask == nil, !pending.isEmpty else { return }
        photoTask = Task {
            // A replaced photo keeps its file name, so the family may not change: announce it.
            var replaced = false
            for item in pending {
                guard let link = URL(string: item.url) else {
                    HearthPublisher.failedPhotoURLs.insert(item.url)
                    continue
                }
                let jpeg = await HearthPhotoDownloader.smallJPEG(from: link)
                guard !Task.isCancelled else { return }
                let before = HearthPublisher.sharedPhotoNames()[item.memberID].flatMap { Hearth.photo(named: $0) }
                if let jpeg, let name = Hearth.savePhoto(jpeg, memberID: item.memberID, from: .bigtable) {
                    if let before, before != jpeg { replaced = true }
                    var sources = HearthPublisher.photoSources
                    sources[item.memberID] = [item.url, name]
                    HearthPublisher.photoSources = sources
                } else {
                    HearthPublisher.failedPhotoURLs.insert(item.url)
                }
            }
            HearthPublisher.photoTask = nil
            if let latest = HearthPublisher.latestFamily {
                HearthPublisher.publishFamily(latest.me, householdName: latest.householdName, userID: latest.userID)
            }
            if replaced { Hearth.postChange() }
        }
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
