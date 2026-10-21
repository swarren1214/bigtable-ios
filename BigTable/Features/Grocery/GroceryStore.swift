import Foundation
import Observation
import OSLog

/// The household's grocery list: the active snapshot from `/v1/bigtable/grocery/snapshots`, the last
/// few lists (history), and every change made in the Grocery tab.
///
/// Checking items off saves a moment later (debounced, as the Expo app did), so a run through
/// the store doesn't send a request per tap. Household members can only check items off; the
/// organizer can also add, edit and remove items and sections, generate a list with AI and
/// restore an older list.
@MainActor
@Observable
final class GroceryStore {
    /// The one list the Grocery tab and Ask BigTable share, so a change in either shows in both.
    static let shared = GroceryStore()

    /// The aisles every list is organized by, in store order (the Expo app's
    /// DEFAULT_GROCERY_SECTIONS). Other sections the AI or the organizer adds sort after these.
    static let defaultSections = ["Produce", "Meat", "Dairy", "Pantry", "Bakery", "Frozen", "Beverages", "Snacks", "Household", "Other"]

    /// Expo saved two seconds after the last change.
    static let saveDelay: Duration = .seconds(2)

    private(set) var snapshots: [GrocerySnapshot] = []
    private(set) var activeSnapshotID: String? { didSet { shareSoon() } }
    private(set) var sections: [GrocerySection] = [] { didSet { shareSoon() } }
    private(set) var checks: [String: Bool] = [:] { didSet { shareSoon() } }
    private(set) var estimatedCost: Double = 0 { didSet { shareSoon() } }
    private(set) var source: GrocerySource?
    private(set) var generatedAt: String?

    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// The first load failed: shown with Try Again in place of the list.
    private(set) var loadError: String?
    private(set) var isSaving = false
    private(set) var isRestoring = false
    /// Something failed after the list was showing (a save, a restore), for an alert.
    var errorMessage: String?

    private let api = BigTableAPI.shared
    private var pendingSave: Task<Void, Never>?
    private var inFlightSave: Task<Void, Never>?
    private var lastSaved: GrocerySaveSignature?
    private var pendingShare: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "grocery")

    // MARK: - What's on the list

    var allItems: [GroceryItem] { sections.flatMap(\.items) }
    var totalCount: Int { allItems.count }
    var checkedCount: Int { allItems.filter { checks[$0.id] == true }.count }
    var remainingCount: Int { totalCount - checkedCount }
    var isEmpty: Bool { totalCount == 0 }
    var hasList: Bool { !sections.isEmpty || activeSnapshotID != nil }

    func isChecked(_ item: GroceryItem) -> Bool { checks[item.id] == true }

    /// Sections in store order (the default aisles first, then the rest alphabetically).
    var orderedSections: [GrocerySection] {
        let defaults = Self.defaultSections.map { $0.lowercased() }
        return sections.sorted { lhs, rhs in
            let left = defaults.firstIndex(of: lhs.name.trimmingCharacters(in: .whitespaces).lowercased())
            let right = defaults.firstIndex(of: rhs.name.trimmingCharacters(in: .whitespaces).lowercased())
            switch (left, right) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// The section names to offer when adding or moving an item: the default aisles plus any
    /// others on this list.
    var sectionChoices: [String] {
        var names = Self.defaultSections
        for section in orderedSections where !names.contains(where: { $0.caseInsensitiveCompare(section.name) == .orderedSame }) {
            names.append(section.name)
        }
        return names
    }

    /// The dates the active list was generated for, when it was generated on this device.
    var activeRange: (start: String, end: String)? {
        guard let activeSnapshotID else { return nil }
        return GroceryRangeMemory.range(for: activeSnapshotID)
    }

    // MARK: - Sharing with the other Hearth apps

    /// Shares the list (its estimate and what's left) with the other Hearth apps a moment after
    /// it changes, so a run of check-offs shares once. Suffice shows it as planned spending.
    private func shareSoon() {
        pendingShare?.cancel()
        pendingShare = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            HearthPublisher.publishGroceries(self.hearthList)
        }
    }

    /// The active list as the other Hearth apps see it, or nil when there's none.
    var hearthList: HearthGroceries.List? {
        guard let activeSnapshotID, totalCount > 0 else { return nil }
        let range = activeRange
        return HearthGroceries.List(
            id: activeSnapshotID,
            estimatedCost: estimatedCost > 0 ? estimatedCost : nil,
            itemCount: totalCount,
            remainingCount: remainingCount,
            generatedAt: ISODay.timestamp(generatedAt),
            startDate: range?.start,
            endDate: range?.end,
            link: "bigtable://grocery"
        )
    }

    // MARK: - Loading

    /// Loads the snapshots and shows the active one. Unsaved changes are saved first so a
    /// refresh never loses them.
    func load() async {
        await flush()
        if !hasLoaded { isLoading = true }
        defer { isLoading = false }
        do {
            let response = try await KitchenStore.shared.grocerySnapshots()
            snapshots = response.snapshots
            let active = response.snapshots.first { $0.id == response.activeSnapshotId } ?? response.snapshots.first
            show(active)
            loadError = nil
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("Couldn't load the grocery list: \(error.localizedDescription, privacy: .public)")
            if hasLoaded {
                errorMessage = FriendlyError.message(error)
            } else {
                loadError = FriendlyError.message(error, fallback: "The grocery list couldn't load. Try again.")
            }
        }
    }

    private func show(_ snapshot: GrocerySnapshot?) {
        activeSnapshotID = snapshot?.id
        sections = snapshot?.sections ?? []
        checks = snapshot?.checks ?? [:]
        estimatedCost = snapshot?.estimatedCost ?? 0
        source = snapshot?.source
        generatedAt = snapshot?.generatedAtIso
        lastSaved = signature
    }

    // MARK: - Checking off

    func toggle(_ item: GroceryItem) {
        checks[item.id] = !isChecked(item)
        changed()
        tellPantry(item, checked: checks[item.id] == true)
    }

    func setSection(_ section: GrocerySection, checked: Bool) {
        for item in section.items where isChecked(item) != checked {
            checks[item.id] = checked
            tellPantry(item, checked: checked)
        }
        changed()
    }

    /// What's checked off came home: the pantry adds it (unchecking takes it back). Items in
    /// Already Have came from the pantry, so they're left alone.
    private func tellPantry(_ item: GroceryItem, checked: Bool) {
        guard !sections.contains(where: { $0.name == Self.alreadyHaveSection && $0.items.contains { $0.id == item.id } }) else { return }
        KitchenStore.shared.groceryChecked(item, listID: activeSnapshotID, checked: checked)
    }

    /// Checks items off without telling the pantry (a receipt put them away already).
    func markBought(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { checks[id] = true }
        changed()
    }

    /// The section a generated list puts what the pantry already has in, checked off.
    static let alreadyHaveSection = "Already Have"

    func uncheckAll() {
        for item in allItems where isChecked(item) { tellPantry(item, checked: false) }
        for key in checks.keys { checks[key] = false }
        changed()
    }

    // MARK: - Organizer edits

    /// Adds an item to a section (created if it's new). Like the Expo app, a manual item adds
    /// about $6 to the estimate.
    func addItem(name: String, quantity: String, to sectionName: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let sectionName = sectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Other" : sectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let millis = Int(Date.now.timeIntervalSince1970 * 1000)
        let item = GroceryItem(id: String("manual:\(millis):\(Self.slug(name))".prefix(120)), name: String(name.prefix(120)), quantity: quantity.isEmpty ? "1" : String(quantity.prefix(240)))
        insert(item, into: sectionName)
        estimatedCost += 6
        changed()
    }

    /// Renames an item, changes its quantity or bulk flag, or moves it to another section.
    func updateItem(id: String, name: String, quantity: String, bulk: Bool, sectionName: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var item = allItems.first(where: { $0.id == id }) else { return }
        item.name = String(name.prefix(120))
        item.quantity = String(quantity.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        item.bulk = bulk
        let target = sectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Other" : sectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIndex = sections.firstIndex { section in section.items.contains { $0.id == id } }
        if let currentIndex, sections[currentIndex].name.caseInsensitiveCompare(target) == .orderedSame,
           let itemIndex = sections[currentIndex].items.firstIndex(where: { $0.id == id }) {
            sections[currentIndex].items[itemIndex] = item
        } else {
            removeFromSections(id)
            insert(item, into: target)
        }
        changed()
    }

    func deleteItem(_ id: String) {
        removeFromSections(id)
        checks[id] = nil
        changed()
    }

    /// Adds an empty section. False when one by that name is already on the list.
    @discardableResult
    func addSection(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !sections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        sections.append(GrocerySection(name: String(name.prefix(80)), icon: Self.legacyIcon(for: name), items: []))
        changed()
        return true
    }

    private func insert(_ item: GroceryItem, into sectionName: String) {
        if let index = sections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) {
            sections[index].items.append(item)
        } else {
            sections.append(GrocerySection(name: String(sectionName.prefix(80)), icon: Self.legacyIcon(for: sectionName), items: [item]))
        }
    }

    /// Removes an item; a section it leaves empty goes too unless it's a default aisle (as in
    /// the Expo app).
    private func removeFromSections(_ id: String) {
        for index in sections.indices {
            sections[index].items.removeAll { $0.id == id }
        }
        sections.removeAll { section in
            section.items.isEmpty && !Self.defaultSections.contains { $0.caseInsensitiveCompare(section.name) == .orderedSame }
        }
    }

    // MARK: - Saving

    private var signature: GrocerySaveSignature {
        GrocerySaveSignature(id: activeSnapshotID, sections: sections, checks: checks, estimatedCost: estimatedCost)
    }

    private func changed() {
        syncActiveSnapshot()
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: GroceryStore.saveDelay)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// Keeps the active entry in History in step with what's on screen.
    private func syncActiveSnapshot() {
        guard let activeSnapshotID, let index = snapshots.firstIndex(where: { $0.id == activeSnapshotID }) else { return }
        snapshots[index].checks = checks
        if AppModel.shared.isOrganizer {
            snapshots[index].sections = sections
            snapshots[index].itemCount = totalCount
            snapshots[index].estimatedCost = estimatedCost
        }
    }

    /// Saves anything waiting right away (leaving the tab, before a refresh).
    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        await saveNow()
    }

    private func saveNow() async {
        // One save at a time, so a new list's id is known before the next save goes out.
        while let running = inFlightSave { await running.value }
        let current = signature
        guard current != lastSaved, hasList else { return }

        let payload: SaveGrocerySnapshotPayload
        if AppModel.shared.isOrganizer {
            payload = SaveGrocerySnapshotPayload(
                id: activeSnapshotID,
                sections: sections,
                checks: checks,
                estimatedCost: max(0, estimatedCost),
                source: activeSnapshotID == nil ? .manual : nil,
                makeActive: true
            )
        } else {
            // Members may only send the id and the checks.
            guard let id = activeSnapshotID else { return }
            payload = SaveGrocerySnapshotPayload(id: id, sections: nil, checks: checks, estimatedCost: nil, source: nil, makeActive: nil)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(payload, sent: current)
            self.inFlightSave = nil
        }
        inFlightSave = task
        await task.value
    }

    private func perform(_ payload: SaveGrocerySnapshotPayload, sent: GrocerySaveSignature) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await KitchenStore.shared.saveGrocerySnapshot(payload)
            if activeSnapshotID == nil || activeSnapshotID == sent.id { activeSnapshotID = saved.id }
            if generatedAt == nil { generatedAt = saved.generatedAtIso }
            if source == nil { source = saved.source }
            upsert(saved)
            syncActiveSnapshot()
            lastSaved = GrocerySaveSignature(id: saved.id, sections: sent.sections, checks: sent.checks, estimatedCost: sent.estimatedCost)
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("Couldn't save the grocery list: \(error.localizedDescription, privacy: .public)")
            errorMessage = FriendlyError.message(error, fallback: "Your grocery list couldn't be saved. Try again.")
        }
    }

    /// Replaces a list in History, or puts a new one first (the API keeps five).
    private func upsert(_ snapshot: GrocerySnapshot) {
        if let index = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            snapshots[index] = snapshot
        } else {
            snapshots.insert(snapshot, at: 0)
            snapshots = Array(snapshots.prefix(5))
        }
    }

    // MARK: - History

    /// Makes an older list the active one again (organizer only).
    func restore(_ snapshot: GrocerySnapshot) async {
        pendingSave?.cancel()
        pendingSave = nil
        while let running = inFlightSave { await running.value }
        isRestoring = true
        defer { isRestoring = false }
        show(snapshot)
        do {
            let saved = try await KitchenStore.shared.saveGrocerySnapshot(SaveGrocerySnapshotPayload(
                id: snapshot.id,
                sections: snapshot.sections,
                checks: snapshot.checks,
                estimatedCost: snapshot.estimatedCost,
                source: nil,
                makeActive: true
            ))
            upsert(saved)
        } catch {
            errorMessage = FriendlyError.message(error, fallback: "That list couldn't be restored. Try again.")
        }
        lastSaved = signature
    }

    // MARK: - AI

    /// The meals planned between two days, from the kitchen, for the API's grocery list.
    static func plannedMeals(from start: String, to end: String) -> [GroceryListRequest.PlannedMeal] {
        let kitchen = KitchenStore.shared
        let size = AppModel.shared.householdSize
        var meals: [GroceryListRequest.PlannedMeal] = []
        for planned in kitchen.plannedSlots(from: start, to: end) {
            let eaters = max(1, size - planned.value.excludedMembers.count)
            if planned.value.recipeItems.isEmpty {
                let title = (planned.value.customMeal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, planned.value.dineOut == nil else { continue }
                meals.append(.init(isoDate: planned.date, day: planned.day.rawValue, slot: planned.slot.rawValue, title: title, eaters: eaters))
                continue
            }
            for item in planned.value.recipeItems {
                let own = item.recipeId.flatMap { kitchen.state.recipes[$0]?.detail }
                meals.append(.init(
                    isoDate: planned.date, day: planned.day.rawValue, slot: planned.slot.rawValue,
                    title: own?.title ?? item.title, eaters: eaters,
                    baseServings: own?.baseServings,
                    ingredients: own?.ingredients.map(\.input)
                ))
            }
        }
        return meals
    }

    /// Asks the AI for a list for the planned meals between two days, and returns it for
    /// review. With `overwrite` off, the new items are merged into the current list.
    func generate(start: String, end: String, weekStart: String, costcoMode: Bool, overwrite: Bool, prompt: String) async throws -> GroceryPreview {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GroceryListRequest(
            costcoMode: costcoMode,
            weekStart: weekStart,
            selectedDates: GroceryDates.days(from: start, to: end),
            startDate: start,
            endDate: end,
            overwriteExisting: overwrite,
            additionalPrompt: trimmed.isEmpty ? nil : String(trimmed.prefix(500)),
            household: HearthHouseholdStore.shared.exists ? HearthHouseholdStore.shared.aiContext() : nil,
            plannedMeals: Self.plannedMeals(from: start, to: end)
        )
        // Built on the device when it can (Apple Intelligence and Pro); the API otherwise.
        let list: GroceryListResponse.List
        let source: GrocerySource
        if let onDevice = try await OnDeviceGroceryList.generate(dates: request.selectedDates ?? [], costcoMode: costcoMode, note: request.additionalPrompt) {
            list = onDevice
            source = .anthropic
        } else {
            let response = try await api.generateGroceryList(request)
            AppModel.shared.updateUsage(response.usage)
            list = response.groceryList
            source = GrocerySource(rawValue: response.generatedBy) ?? .anthropic
        }
        let replacing = overwrite || sections.isEmpty
        let nextSections = replacing ? list.sections : Self.merge(sections, list.sections)
        return GroceryPreview(
            sections: nextSections,
            estimatedCost: replacing ? list.estimatedCost : max(estimatedCost, list.estimatedCost),
            source: source,
            overwrite: replacing,
            start: start,
            end: end
        )
    }

    /// "Existing" or "New" in the preview: is this item already on the current list?
    func isOnCurrentList(_ item: GroceryItem, section: String) -> Bool {
        let key = Self.itemKey(section, item.name)
        return sections.contains { current in current.items.contains { Self.itemKey(current.name, $0.name) == key } }
    }

    /// Saves a previewed list as a new, active list (the Expo app's "Publish Grocery List").
    func publish(_ preview: GroceryPreview) async throws {
        pendingSave?.cancel()
        pendingSave = nil
        while let running = inFlightSave { await running.value }
        var nextChecks = preview.overwrite ? [:] : carriedChecks(into: preview.sections)
        for item in preview.sections.first(where: { $0.name == Self.alreadyHaveSection })?.items ?? [] { nextChecks[item.id] = true }
        let saved = try await KitchenStore.shared.saveGrocerySnapshot(SaveGrocerySnapshotPayload(
            id: nil,
            sections: preview.sections,
            checks: nextChecks,
            estimatedCost: max(0, preview.estimatedCost),
            source: preview.source,
            makeActive: true
        ))
        GroceryRangeMemory.remember(start: preview.start, end: preview.end, for: saved.id)
        upsert(saved)
        show(saved)
    }

    /// Merging keeps what was already checked off, matched by section and name (the merged
    /// list gives items new ids).
    private func carriedChecks(into newSections: [GrocerySection]) -> [String: Bool] {
        var checkedKeys = Set<String>()
        for section in sections {
            for item in section.items where checks[item.id] == true {
                checkedKeys.insert(Self.itemKey(section.name, item.name))
            }
        }
        var result: [String: Bool] = [:]
        for section in newSections {
            for item in section.items where checkedKeys.contains(Self.itemKey(section.name, item.name)) {
                result[item.id] = true
            }
        }
        return result
    }

    // MARK: - Sharing

    /// The list as text for Messages or AirDrop: what's still needed, by section.
    func shareText(includeCost: Bool) -> String {
        var lines: [String] = []
        if let range = activeRange {
            lines.append("Grocery list · \(GroceryDates.label(start: range.start, end: range.end))")
        } else {
            lines.append("Grocery list")
        }
        var anything = false
        for section in orderedSections {
            let needed = section.items.filter { checks[$0.id] != true }
            guard !needed.isEmpty else { continue }
            anything = true
            lines.append("")
            lines.append(section.name.uppercased())
            for item in needed {
                let quantity = item.quantity.trimmingCharacters(in: .whitespaces)
                lines.append(quantity.isEmpty ? "• \(item.name)" : "• \(item.name) — \(quantity)")
            }
        }
        if !anything {
            lines.append("")
            lines.append("Everything's checked off.")
        }
        if includeCost, estimatedCost > 0 {
            lines.append("")
            lines.append("Estimated cost: \(GroceryFormat.cost(estimatedCost))")
        }
        lines.append("")
        lines.append("From BigTable")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers (ported from the Expo app)

    static func itemKey(_ section: String, _ name: String) -> String {
        "\(section.trimmingCharacters(in: .whitespaces).lowercased())::\(name.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    static func slug(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    }

    /// Combines two lists: items with the same name in a section become one, with their meals
    /// together (Expo's mergeGrocerySections).
    static func merge(_ base: [GrocerySection], _ incoming: [GrocerySection]) -> [GrocerySection] {
        struct Bucket {
            var icon: String
            var keys: [String] = []
            var items: [String: GroceryItem] = [:]
        }
        var order: [String] = []
        var buckets: [String: Bucket] = [:]
        for section in base + incoming {
            let name = section.name.trimmingCharacters(in: .whitespaces)
            var bucket = buckets[name] ?? Bucket(icon: section.icon)
            if buckets[name] == nil { order.append(name) }
            for item in section.items {
                let key = item.name.trimmingCharacters(in: .whitespaces).lowercased()
                if var existing = bucket.items[key] {
                    for meal in item.meals where !existing.meals.contains(meal) { existing.meals.append(meal) }
                    existing.bulk = existing.bulk || item.bulk
                    bucket.items[key] = existing
                } else {
                    bucket.keys.append(key)
                    bucket.items[key] = GroceryItem(
                        id: String("\(slug(name)):\(slug(key))".prefix(120)),
                        name: item.name,
                        quantity: item.quantity,
                        meals: item.meals,
                        bulk: item.bulk
                    )
                }
            }
            buckets[name] = bucket
        }
        return order.compactMap { name in
            guard let bucket = buckets[name] else { return nil }
            let items = bucket.keys.compactMap { key -> GroceryItem? in
                guard var item = bucket.items[key] else { return nil }
                item.meals = Array(item.meals.prefix(6))
                return item
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return GrocerySection(name: name, icon: bucket.icon, items: items)
        }
    }

    /// The emoji the Expo app stored as a section's `icon`, so lists stay identical in both
    /// apps (the native app draws SF Symbols from `GroceryAisleStyle` instead).
    static func legacyIcon(for section: String) -> String {
        let name = section.trimmingCharacters(in: .whitespaces).lowercased()
        if name.contains("produce") { return "🥬" }
        if name.contains("meat") || name.contains("protein") { return "🥩" }
        if name.contains("dairy") || name.contains("egg") { return "🥛" }
        if name.contains("pantry") || name.contains("can") { return "🥫" }
        if name.contains("frozen") { return "❄️" }
        if name.contains("bakery") { return "🥖" }
        if name.contains("beverage") || name.contains("drink") { return "🥤" }
        if name.contains("snack") { return "🍿" }
        if name.contains("household") || name.contains("clean") { return "🧽" }
        return "🛒"
    }
}

/// What was last saved, to skip saves that would change nothing.
struct GrocerySaveSignature: Equatable {
    var id: String?
    var sections: [GrocerySection]
    var checks: [String: Bool]
    var estimatedCost: Double
}

/// A list the AI made, waiting for the organizer to look it over and save it.
struct GroceryPreview: Identifiable, Hashable {
    let id = UUID()
    var sections: [GrocerySection]
    var estimatedCost: Double
    var source: GrocerySource
    /// Replaces the current list (true) or was merged into it (false).
    var overwrite: Bool
    var start: String
    var end: String

    var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }
}

/// The days a list was generated for, by snapshot id (the API doesn't store them), for the
/// header and the shared text. Kept with the list in the family's kitchen, so every device has
/// them, and on this device for lists from before that.
enum GroceryRangeMemory {
    private static let key = SettingsKey.grocerySnapshotRanges

    static func range(for snapshotID: String) -> (start: String, end: String)? {
        if let grocery = KitchenStore.shared.state.groceries[snapshotID], let start = grocery.start, let end = grocery.end {
            return (start, end)
        }
        guard let stored = UserDefaults.standard.dictionary(forKey: key)?[snapshotID] as? String else { return nil }
        let parts = stored.split(separator: "|").map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    static func remember(start: String, end: String, for snapshotID: String) {
        var stored = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        stored[snapshotID] = "\(start)|\(end)"
        // Five lists are kept by the API; a few extra entries are harmless, but don't grow forever.
        if stored.count > 20 { stored = Dictionary(uniqueKeysWithValues: stored.suffix(20).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(stored, forKey: key)
        KitchenStore.shared.setRange(start: start, end: end, forGrocery: snapshotID)
    }
}

/// Day ranges for the AI list ("YYYY-MM-DD" strings).
enum GroceryDates {
    /// Every day from `start` through `end`.
    static func days(from start: String, to end: String) -> [String] {
        var days: [String] = []
        var cursor = start
        while cursor <= end, days.count < 60 {
            days.append(cursor)
            cursor = ISODay.adding(days: 1, to: cursor)
        }
        return days
    }

    /// "Oct 12 – 18", or "Oct 12" for one day.
    static func label(start: String, end: String) -> String {
        guard let first = ISODay.date(from: start), let last = ISODay.date(from: end) else { return "" }
        if start == end || last <= first {
            return first.formatted(.dateTime.month(.abbreviated).day())
        }
        return (first..<last).formatted(.interval.month(.abbreviated).day())
    }

    static func date(_ day: String) -> Date {
        ISODay.date(from: day) ?? Calendar.current.startOfDay(for: .now)
    }
}

enum GroceryFormat {
    /// "$142", as the Expo app showed it (whole dollars).
    static func cost(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    /// Where a list came from, for History.
    static func sourceLabel(_ source: GrocerySource) -> String {
        switch source {
        case .anthropic: "Made with AI"
        case .fallback: "Made from your plan"
        case .manual: "Made by hand"
        }
    }

    static func sourceSymbol(_ source: GrocerySource) -> String {
        switch source {
        case .anthropic: "sparkles"
        case .fallback: "list.bullet.clipboard"
        case .manual: "pencil"
        }
    }

    /// "For Fajitas, Chili".
    static func meals(_ meals: [String]) -> String? {
        let names = meals.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return "For " + names.formatted(.list(type: .and, width: .narrow))
    }
}
