import Foundation
import os

/// The one-time move of a household's private data from the server into the kitchen in
/// iCloud: recipes (with their photos), tags, every planned week and the grocery lists. The
/// server keeps its copy for 30 days after it's told the move happened, then deletes it.
///
/// Only the organizer's phone moves anything (everyone else's BigTable used the organizer's
/// data), and only with iCloud available, so nothing is left on a single device.
@MainActor
enum KitchenMove {
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "kitchen")
    private static var isRunning = false

    private static func doneKey(_ userID: String) -> String { "kitchen.moved.\(userID)" }

    static func runIfNeeded(model: AppModel) async {
        guard !isRunning, !ScreenshotMode.isOn, model.phase == .ready, model.isOrganizer,
              let userID = model.userID, !UserDefaults.standard.bool(forKey: doneKey(userID)),
              HearthHouseholdStore.shared.account == .available,
              KitchenStore.shared.location == .personal else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            // Another of this person's devices may have moved it already: look first.
            await KitchenStore.shared.syncNow()
            if KitchenStore.shared.state.settings.movedAt != nil {
                UserDefaults.standard.set(true, forKey: doneKey(userID))
                return
            }
            let export = try await BigTableAPI.shared.kitchenExport()
            let state = await convert(export)
            KitchenStore.shared.importState(state)
            KitchenStore.shared.persistNow()
            await KitchenStore.shared.syncNow()
            try await BigTableAPI.shared.markKitchenMoved()
            UserDefaults.standard.set(true, forKey: doneKey(userID))
            log.notice("Moved \(state.recipes.count) recipes and \(state.slots.count) planned meals into iCloud")
        } catch let error as APIError where error.status == 409 || error.status == 404 {
            // A member of someone else's household on the server, or a server without the
            // export: nothing of theirs to move.
            UserDefaults.standard.set(true, forKey: doneKey(userID))
        } catch {
            log.error("The move to iCloud will try again: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func convert(_ export: KitchenExport) async -> KitchenState {
        // Imported values are as old as can be, so anything edited in iCloud since wins.
        let now = Date(timeIntervalSince1970: 0)
        var state = KitchenState()

        // Recipe photos the family uploaded come into the kitchen too (published ones keep
        // their public photo).
        let toDownload = export.recipes.filter { $0.status != .published && ($0.imageUrl ?? "").hasPrefix("http") }
        let photos = await withTaskGroup(of: (String, String?).self) { group in
            for recipe in toDownload {
                guard let link = recipe.imageUrl, let url = URL(string: link) else { continue }
                group.addTask {
                    guard let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return (recipe.id, nil) }
                    let ext = link.lowercased().contains(".png") ? "png" : link.lowercased().contains(".webp") ? "webp" : "jpg"
                    return (recipe.id, KitchenPhotos.save(data, ext: ext))
                }
            }
            var found: [String: String] = [:]
            for await (id, stored) in group { if let stored { found[id] = stored } }
            return found
        }

        for var detail in export.recipes {
            if let stored = photos[detail.id] { detail.imageUrl = stored }
            let deleted = detail.status == .removed
            if deleted { detail.status = .draft }
            state.recipes[detail.id] = KitchenRecipe(detail: detail, deletedAt: deleted ? now : nil, updatedAt: now)
        }
        for tag in export.tags {
            state.tags[tag.id] = KitchenTag(tag: tag, updatedAt: now)
        }

        // "Not eating" held the server's names for people; the plan now uses household first names.
        let household = HearthHouseholdStore.shared
        func planName(_ old: String) -> String {
            guard household.exists else { return old }
            let key = HearthNames.normalized(old)
            if let person = household.people.first(where: { HearthNames.normalized($0.name) == key || HearthNames.normalized($0.firstName) == key }) {
                return AppModel.planName(person)
            }
            return old
        }
        for plan in export.plans {
            for (dayKey, slots) in plan.days {
                guard let day = DayOfWeek(rawValue: dayKey) else { continue }
                for (slotKey, value) in slots {
                    guard let slot = MealSlotType(rawValue: slotKey) else { continue }
                    var value = value
                    value.excludedMembers = value.excludedMembers.map(planName)
                    let entry = KitchenSlot(weekStart: plan.weekStart, day: day, slot: slot, value: value, updatedAt: now)
                    if !value.isEmpty || !value.snackItems.isEmpty { state.slots[entry.key] = entry }
                }
            }
        }
        for snapshot in export.grocery.snapshots.prefix(5) {
            state.groceries[snapshot.id] = KitchenGrocery(snapshot: snapshot, updatedAt: now)
        }
        state.settings = KitchenSettings(activeGroceryID: export.grocery.activeSnapshotId, updatedAt: now)
        return state
    }
}
