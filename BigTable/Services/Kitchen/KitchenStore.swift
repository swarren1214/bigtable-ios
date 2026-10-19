import CloudKit
import Foundation
import Observation
import os

/// BigTable's kitchen: the family's recipes, meal plan, grocery lists and tags, kept in their
/// iCloud (the Hearth container's `Kitchen` zone) instead of on the server.
///
/// Where it lives:
/// - Someone in their own household (or with no household): their private database. When the
///   household has other parents and adults, it's shared with them (`KitchenSharing`).
/// - Someone who joined another family's household: that family's kitchen, shared with them.
///   Their own recipes come along the first time.
///
/// It syncs on the household's engines (`HearthHouseholdStore`, as a `HearthZoneParticipant`),
/// so BigTable never runs two engines on one database, and the other Hearth apps never
/// download recipes. Screens use the calls in `KitchenStore+API.swift`, which match the API
/// calls they used before.
@MainActor
@Observable
final class KitchenStore: HearthZoneParticipant {
    static let shared = KitchenStore()
    static let kitchenZoneName = "Kitchen"
    let zoneName = KitchenStore.kitchenZoneName

    enum Location: Hashable {
        /// This account's own kitchen, in its private database.
        case personal
        /// Another family's kitchen this account was added to.
        case shared(ownerName: String)

        /// Each family's kitchen has its own files, so one family's data never reaches another's.
        var fileKey: String {
            switch self {
            case .personal: "personal"
            case .shared(let ownerName): "shared-" + ownerName.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            }
        }
    }

    private(set) var state = KitchenState()
    private(set) var location: Location = .personal
    /// Goes up whenever iCloud brought changes, so screens can reload.
    private(set) var revision = 0

    @ObservationIgnored private var systemFields: [String: Data] = [:]
    /// Each grocery list's ticks as a screen last loaded them (see saveGrocerySnapshot).
    @ObservationIgnored var loadedChecks: [String: [String: Bool]] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "kitchen")

    /// Which family's kitchen this account joined (its zone owner), once accepted.
    private static let joinedOwnerKey = "kitchen.joinedOwner"

    var household: HearthHouseholdStore { .shared }

    // MARK: - Starting

    /// Call at launch, before the household store starts.
    func prepare() {
        guard !started else { return }
        started = true
        household.register(self)
        location = expectedLocation
        load()
    }

    /// Where the kitchen should be now.
    private var expectedLocation: Location {
        if case .member(let ownerName) = household.mode,
           UserDefaults.standard.string(forKey: Self.joinedOwnerKey) == ownerName {
            return .shared(ownerName: ownerName)
        }
        return .personal
    }

    /// Follows the household: joined, left, or the kitchen share accepted. Call when the
    /// household changes.
    func refreshLocation() {
        guard started else { return }
        // Left that family's household: their kitchen doesn't stay on this device.
        if case .shared(let ownerName) = location, household.mode != .member(ownerName: ownerName) {
            UserDefaults.standard.removeObject(forKey: Self.joinedOwnerKey)
            saveTask?.cancel()
            KitchenFiles.remove(location.fileKey)
            state = KitchenState()
            systemFields = [:]
            location = .personal
            load()
            queueEverything()
            revision += 1
        }
        let next = expectedLocation
        guard next != location else { return }
        log.notice("Kitchen moves to \(next.fileKey, privacy: .public)")
        let personal = location == .personal ? state : nil
        persistNow()
        location = next
        load()
        if case .shared(let ownerName) = next, let personal { bringAlong(personal, into: ownerName) }
        queueEverything()
        revision += 1
    }

    /// The first time someone joins a family's kitchen, their own recipes and tags come too.
    private func bringAlong(_ personal: KitchenState, into ownerName: String) {
        let key = "kitchen.broughtAlong.\(ownerName)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let now = Date.now
        for (id, recipe) in personal.recipes where state.recipes[id] == nil && recipe.deletedAt == nil {
            var copy = recipe
            copy.updatedAt = now
            state.recipes[id] = copy
        }
        for (id, tag) in personal.tags where state.tags[id] == nil && !state.tags.values.contains(where: { $0.tag.normalized == tag.tag.normalized }) {
            state.tags[id] = KitchenTag(tag: tag.tag, updatedAt: now)
        }
        scheduleSave()
    }

    // MARK: - Zone

    var zoneLocation: (zoneID: CKRecordZone.ID, isShared: Bool)? {
        switch location {
        case .personal: (CKRecordZone.ID(zoneName: zoneName), false)
        case .shared(let ownerName): (CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName), true)
        }
    }

    // MARK: - Changing (screens call these through KitchenStore+API)

    func put(recipe: KitchenRecipe) {
        state.recipes[recipe.detail.id] = recipe
        changed(KitchenRecords.recipeName(recipe.detail.id))
    }

    func put(slot: KitchenSlot) {
        if slot.value.isEmpty && slot.value.snackItems.isEmpty && slot.value.excludedMembers.isEmpty && !slot.value.completed {
            guard state.slots[slot.key] != nil else { return }
            state.slots[slot.key] = nil
            removed(KitchenRecords.slotName(slot.key))
        } else {
            state.slots[slot.key] = slot
            changed(KitchenRecords.slotName(slot.key))
        }
    }

    func put(grocery: KitchenGrocery) {
        state.groceries[grocery.snapshot.id] = grocery
        changed(KitchenRecords.groceryName(grocery.snapshot.id))
        // Keep the newest five lists, as the server did.
        let old = state.groceries.values.sorted { $0.snapshot.generatedAtIso > $1.snapshot.generatedAtIso }.dropFirst(5)
        for list in old where list.snapshot.id != state.settings.activeGroceryID {
            state.groceries[list.snapshot.id] = nil
            removed(KitchenRecords.groceryName(list.snapshot.id))
        }
    }

    func setActiveGrocery(_ id: String?) {
        guard state.settings.activeGroceryID != id else { return }
        state.settings.activeGroceryID = id
        state.settings.updatedAt = .now
        changed(KitchenRecords.settingsName)
    }

    func put(tag: KitchenTag) {
        state.tags[tag.tag.id] = tag
        changed(KitchenRecords.tagName(tag.tag.id))
    }

    func removeTag(_ id: String) {
        guard state.tags[id] != nil else { return }
        state.tags[id] = nil
        removed(KitchenRecords.tagName(id))
    }

    /// Replaces everything (the one-time move from the server). Queues every record.
    func importState(_ imported: KitchenState) {
        for (id, recipe) in imported.recipes where (state.recipes[id]?.updatedAt ?? .distantPast) < recipe.updatedAt { state.recipes[id] = recipe }
        for (key, slot) in imported.slots where state.slots[key] == nil { state.slots[key] = slot }
        for (id, list) in imported.groceries where state.groceries[id] == nil { state.groceries[id] = list }
        for (id, tag) in imported.tags where state.tags[id] == nil { state.tags[id] = tag }
        if state.settings.activeGroceryID == nil { state.settings.activeGroceryID = imported.settings.activeGroceryID }
        state.settings.movedAt = state.settings.movedAt ?? .now
        state.settings.updatedAt = .now
        queueEverything()
        scheduleSave()
        revision += 1
    }

    private func changed(_ recordName: String) {
        queue([.saveRecord(recordID(recordName))])
        scheduleSave()
    }

    private func removed(_ recordName: String) {
        systemFields[recordName] = nil
        queue([.deleteRecord(recordID(recordName))])
        scheduleSave()
    }

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneLocation?.zoneID ?? CKRecordZone.ID(zoneName: zoneName))
    }

    private func queue(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        guard let zone = zoneLocation else { return }
        if !zone.isShared { household.ensurePrivateZone(zone.zoneID) }
        household.queueZoneChanges(changes, isShared: zone.isShared)
    }

    private func queueEverything() {
        let names = state.recipes.keys.map(KitchenRecords.recipeName)
            + state.slots.keys.map(KitchenRecords.slotName)
            + state.groceries.keys.map(KitchenRecords.groceryName)
            + state.tags.keys.map(KitchenRecords.tagName)
            + (state.settings.updatedAt > .distantPast ? [KitchenRecords.settingsName] : [])
        queue(names.map { .saveRecord(recordID($0)) })
    }

    /// Sends and fetches now (pull to refresh).
    func syncNow() async {
        guard let zone = zoneLocation else { return }
        await household.syncZoneNow(isShared: zone.isShared)
    }

    // MARK: - HearthZoneParticipant

    func zoneRecord(for recordID: CKRecord.ID) -> CKRecord? {
        let name = recordID.recordName
        let record = cachedRecord(recordID)
        return KitchenRecords.record(named: name, in: state, base: record, recordID: recordID)
    }

    func zoneFetched(modifications: [CKRecord], deletions: [CKDatabase.RecordZoneChange.Deletion]) {
        var next = state
        for record in modifications {
            cache(record)
            KitchenRecords.merge(record, into: &next)
        }
        for deletion in deletions {
            let name = deletion.recordID.recordName
            systemFields[name] = nil
            KitchenRecords.remove(named: name, from: &next)
        }
        if next != state {
            state = next
            revision += 1
        }
        scheduleSave()
    }

    func zoneSent(saved: [CKRecord], deleted: [CKRecord.ID], failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave], isShared: Bool) -> [CKSyncEngine.PendingRecordZoneChange] {
        for record in saved { cache(record) }
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in failedSaves {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                if let server = failure.error.serverRecord {
                    cache(server)
                    var next = state
                    // Theirs wins only when its own clock says it's newer.
                    if KitchenRecords.merge(server, into: &next) {
                        state = next
                        revision += 1
                        continue
                    }
                }
                retry.append(.saveRecord(recordID))
            case .zoneNotFound:
                if isShared {
                    // The family stopped sharing the kitchen, or removed this person.
                    UserDefaults.standard.removeObject(forKey: Self.joinedOwnerKey)
                    refreshLocation()
                    return []
                }
                household.ensurePrivateZone(recordID.zoneID)
                systemFields[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
            case .unknownItem:
                systemFields[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
            case .batchRequestFailed:
                retry.append(.saveRecord(recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited, .notAuthenticated, .operationCancelled, .accountTemporarilyUnavailable:
                break
            default:
                log.error("Kitchen save failed: \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        scheduleSave()
        return retry
    }

    func zoneDatabaseChanged(added: [CKRecordZone.ID], deleted: [CKDatabase.DatabaseChange.Deletion], isShared: Bool) {
        guard isShared else {
            if deleted.contains(where: { $0.reason == .encryptedDataReset }), location == .personal {
                // The iCloud keys were reset: put back what's on this device.
                systemFields = [:]
                queueEverything()
            }
            return
        }
        if case .member(let ownerName) = household.mode, added.contains(where: { $0.ownerName == ownerName }) {
            // Accepted on another device, or by `KitchenSharing.joinIfNeeded`.
            markJoined(ownerName)
        }
        if case .shared(let ownerName) = location, deleted.contains(where: { $0.zoneID.ownerName == ownerName }) {
            UserDefaults.standard.removeObject(forKey: Self.joinedOwnerKey)
            refreshLocation()
        }
    }

    func markJoined(_ ownerName: String) {
        UserDefaults.standard.set(ownerName, forKey: Self.joinedOwnerKey)
        refreshLocation()
    }

    var hasJoinedFamilyKitchen: Bool {
        if case .shared = location { true } else { false }
    }

    func zoneEngineReset(isShared: Bool) {
        refreshLocation()
        // The zone's records are as they were; the new engine just needs to know what to send.
        guard let zone = zoneLocation, zone.isShared == isShared else { return }
        queueEverything()
    }

    func zoneAccountDidChange() {
        UserDefaults.standard.removeObject(forKey: Self.joinedOwnerKey)
        KitchenFiles.removeAll()
        systemFields = [:]
        state = KitchenState()
        location = .personal
        revision += 1
    }

    // MARK: - Saving on the device

    private func load() {
        state = KitchenFiles.loadState(location.fileKey) ?? KitchenState()
        systemFields = KitchenFiles.loadFields(location.fileKey)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    func persistNow() {
        saveTask?.cancel()
        KitchenFiles.saveState(state, location.fileKey)
        KitchenFiles.saveFields(systemFields, location.fileKey)
        // Photos any kitchen on this device still uses.
        let others = KitchenFiles.allStates().flatMap { $0.recipes.values }
        let photos = Set((Array(state.recipes.values) + others).compactMap { KitchenPhotos.name(in: $0.detail.imageUrl) })
        KitchenPhotos.clean(keeping: photos)
    }

    private func cache(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        systemFields[record.recordID.recordName] = coder.encodedData
    }

    private func cachedRecord(_ recordID: CKRecord.ID) -> CKRecord? {
        guard let data = systemFields[recordID.recordName],
              let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordID.zoneID == recordID.zoneID else { return nil }
        return record
    }
}

// MARK: - Records

/// Kitchen values ↔ CloudKit records. Content is JSON in `encryptedValues`, so it's
/// end-to-end encrypted; recipe photos are assets.
nonisolated enum KitchenRecords {
    static let settingsName = "settings"

    static func recipeName(_ id: String) -> String { "recipe-" + id }
    static func slotName(_ key: String) -> String { "slot-" + key }
    static func groceryName(_ id: String) -> String { "grocery-" + id }
    static func tagName(_ id: String) -> String { "tag-" + id }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }()

    /// The record to upload for `name`, or nil when the value is gone.
    static func record(named name: String, in state: KitchenState, base: CKRecord?, recordID: CKRecord.ID) -> CKRecord? {
        func make(_ type: String) -> CKRecord { base ?? CKRecord(recordType: type, recordID: recordID) }
        if let id = name.dropPrefix("recipe-"), let recipe = state.recipes[id] {
            let record = make("Recipe")
            write(recipe, updatedAt: recipe.updatedAt, to: record)
            if let photo = KitchenPhotos.name(in: recipe.detail.imageUrl) {
                // A photo that hasn't arrived on this device yet is left as it is in iCloud.
                let url = KitchenPhotos.url(named: photo)
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    record["photo"] = CKAsset(fileURL: url)
                    record["photoName"] = photo as NSString
                }
            } else {
                record["photo"] = nil
                record["photoName"] = nil
            }
            return record
        }
        if let key = name.dropPrefix("slot-"), let slot = state.slots[key] {
            let record = make("PlanSlot")
            write(slot, updatedAt: slot.updatedAt, to: record)
            record["weekStart"] = slot.weekStart as NSString
            return record
        }
        if let id = name.dropPrefix("grocery-"), let list = state.groceries[id] {
            let record = make("GroceryList")
            write(list, updatedAt: list.updatedAt, to: record)
            return record
        }
        if let id = name.dropPrefix("tag-"), let tag = state.tags[id] {
            let record = make("RecipeTag")
            write(tag, updatedAt: tag.updatedAt, to: record)
            return record
        }
        if name == settingsName {
            let record = make("KitchenSettings")
            write(state.settings, updatedAt: state.settings.updatedAt, to: record)
            return record
        }
        return nil
    }

    private static func write(_ value: some Encodable, updatedAt: Date, to record: CKRecord) {
        record.encryptedValues["content"] = (try? encoder.encode(value)).map { $0 as NSData }
        record["updatedAt"] = updatedAt as NSDate
    }

    private static func content<T: Decodable>(_ type: T.Type, from record: CKRecord) -> T? {
        guard let data = record.encryptedValues["content"] as? Data else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Takes in a fetched record when it's newer than what's here. Returns whether it did.
    @discardableResult
    static func merge(_ record: CKRecord, into state: inout KitchenState) -> Bool {
        let name = record.recordID.recordName
        switch record.recordType {
        case "Recipe":
            guard let id = name.dropPrefix("recipe-"), var incoming = content(KitchenRecipe.self, from: record),
                  incoming.updatedAt > (state.recipes[id]?.updatedAt ?? .distantPast) else { return false }
            // The photo arrives as an asset; keep it under the name it was uploaded with.
            if let photo = record["photoName"] as? String, KitchenPhotos.name(in: KitchenPhotos.scheme + photo) != nil,
               let asset = record["photo"] as? CKAsset, let file = asset.fileURL, let data = try? Data(contentsOf: file) {
                let target = KitchenPhotos.url(named: photo)
                if !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                    try? data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                incoming.detail.imageUrl = KitchenPhotos.scheme + photo
            }
            state.recipes[id] = incoming
            return true
        case "PlanSlot":
            guard let key = name.dropPrefix("slot-"), let incoming = content(KitchenSlot.self, from: record),
                  incoming.updatedAt > (state.slots[key]?.updatedAt ?? .distantPast) else { return false }
            state.slots[key] = incoming
            return true
        case "GroceryList":
            guard let id = name.dropPrefix("grocery-"), let incoming = content(KitchenGrocery.self, from: record),
                  incoming.updatedAt > (state.groceries[id]?.updatedAt ?? .distantPast) else { return false }
            state.groceries[id] = incoming
            return true
        case "RecipeTag":
            guard let id = name.dropPrefix("tag-"), let incoming = content(KitchenTag.self, from: record),
                  incoming.updatedAt > (state.tags[id]?.updatedAt ?? .distantPast) else { return false }
            state.tags[id] = incoming
            return true
        case "KitchenSettings":
            guard let incoming = content(KitchenSettings.self, from: record), incoming.updatedAt > state.settings.updatedAt else { return false }
            state.settings = incoming
            return true
        default:
            return false
        }
    }

    static func remove(named name: String, from state: inout KitchenState) {
        if let id = name.dropPrefix("recipe-") { state.recipes[id] = nil }
        if let key = name.dropPrefix("slot-") { state.slots[key] = nil }
        if let id = name.dropPrefix("grocery-") { state.groceries[id] = nil }
        if let id = name.dropPrefix("tag-") { state.tags[id] = nil }
    }
}

private extension String {
    nonisolated func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

// MARK: - Files

/// The kitchen on the device: Application Support/Kitchen/<personal|shared>.json and the
/// CloudKit system fields beside it.
nonisolated enum KitchenFiles {
    private static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Kitchen", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func stateURL(_ key: String) -> URL { folder.appending(path: "\(key).json", directoryHint: .notDirectory) }
    private static func fieldsURL(_ key: String) -> URL { folder.appending(path: "\(key)-fields.plist", directoryHint: .notDirectory) }

    static func loadState(_ key: String) -> KitchenState? {
        guard let data = try? Data(contentsOf: stateURL(key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try? decoder.decode(KitchenState.self, from: data)
    }

    static func saveState(_ state: KitchenState, _ key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func loadFields(_ key: String) -> [String: Data] {
        guard let data = try? Data(contentsOf: fieldsURL(key)),
              let fields = try? PropertyListDecoder().decode([String: Data].self, from: data) else { return [:] }
        return fields
    }

    static func saveFields(_ fields: [String: Data], _ key: String) {
        guard let data = try? PropertyListEncoder().encode(fields) else { return }
        try? data.write(to: fieldsURL(key), options: .atomic)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: stateURL(key))
        try? FileManager.default.removeItem(at: fieldsURL(key))
    }

    /// Every kitchen saved on this device.
    static func allStates() -> [KitchenState] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { loadState(String($0.dropLast(5))) }
    }
}
