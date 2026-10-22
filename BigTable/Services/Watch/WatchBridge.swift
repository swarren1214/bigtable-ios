import Foundation
import Observation
import os
import WatchConnectivity

/// The iPhone's side of the Apple Watch app: sends the watch the next meals (with their steps)
/// and the grocery list whenever they change, and carries out what the watch sends back
/// (grocery check-offs, Tell the Pantry). See Shared/WatchSnapshot.swift.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "watch")
    private var started = false
    private var pushTask: Task<Void, Never>?
    private var lastSent: WatchSnapshot?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    /// Call once the kitchen is ready (after `KitchenStore.prepare()`).
    func start() {
        guard !started, let session else { return }
        started = true
        session.delegate = self
        session.activate()
        observe()
    }

    /// Sends a fresh snapshot soon (changes often come in bursts, like checking off a section).
    func pushSoon() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await push()
        }
    }

    /// Re-sends when the plan, the recipes or the grocery list change.
    private func observe() {
        withObservationTracking {
            _ = KitchenStore.shared.state
            _ = GroceryStore.shared.sections
            _ = GroceryStore.shared.checks
            _ = GroceryStore.shared.activeSnapshotID
        } onChange: {
            // The bridge lives as long as the app (`shared`).
            Task { @MainActor in
                WatchBridge.shared.pushSoon()
                WatchBridge.shared.observe()
            }
        }
    }

    private func push() async {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let snapshot = await makeSnapshot()
        // `generatedAt` changes every time; compare the rest.
        if var last = lastSent {
            last.generatedAt = snapshot.generatedAt
            if last == snapshot { return }
        }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try session.updateApplicationContext([WatchKeys.snapshot: data])
            lastSent = snapshot
        } catch {
            log.error("Couldn't send the watch its snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - The snapshot

    func makeSnapshot() async -> WatchSnapshot {
        let kitchen = KitchenStore.shared
        let today = ISODay.string(from: .now)
        let tomorrow = ISODay.adding(days: 1, to: today)
        let times = HearthMealTimes.current

        var meals: [WatchMeal] = []
        for planned in kitchen.plannedSlots(from: today, to: tomorrow) {
            let day = ISODay.date(from: planned.date) ?? .now
            var recipes: [WatchRecipe] = []
            var servings: Int?
            var minutes: Int?
            for item in planned.value.recipeItems {
                guard let id = item.recipeId,
                      let detail = try? await kitchen.recipe(id, versionId: item.recipeVersionId) else { continue }
                let steps = detail.instructions
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { WatchStep(text: $0, timerSeconds: StepTimer.seconds(in: $0)) }
                recipes.append(WatchRecipe(id: id, title: detail.title, steps: steps))
                if servings == nil, detail.baseServings > 0 { servings = Int(detail.baseServings.rounded()) }
                if detail.totalMinutes > 0 { minutes = max(minutes ?? 0, detail.totalMinutes) }
            }
            meals.append(WatchMeal(
                id: "\(planned.date)-\(planned.slot.rawValue)",
                slot: planned.slot.rawValue,
                startsAt: times.start(for: planned.slot.rawValue, on: day),
                title: planned.value.title,
                servings: servings,
                minutes: minutes,
                recipes: recipes,
                completed: planned.value.completed
            ))
        }

        let groceries = GroceryStore.shared
        if !groceries.hasLoaded { await groceries.load() }
        var grocery: WatchGrocery?
        if let listID = groceries.activeSnapshotID {
            let sections = groceries.orderedSections
                // What the pantry already has isn't shopping.
                .filter { $0.name != GroceryStore.alreadyHaveSection && !$0.items.isEmpty }
                .map { section in
                    WatchGrocerySection(name: section.name, icon: section.icon, items: section.items.map { item in
                        WatchGroceryItem(id: item.id, name: item.name, quantity: item.quantity,
                                         note: item.meals.isEmpty ? nil : "For " + item.meals.joined(separator: ", "))
                    })
                }
            grocery = WatchGrocery(id: listID, sections: sections, checks: groceries.checks)
        }

        return WatchSnapshot(generatedAt: .now, meals: meals, grocery: grocery)
    }

    // MARK: - From the watch

    private func handle(_ message: [String: Any]) async -> [String: Any] {
        switch message[WatchKeys.kind] as? String {
        case WatchKeys.check:
            guard let id = message[WatchKeys.itemID] as? String,
                  let checked = message[WatchKeys.checked] as? Bool else { return [:] }
            let groceries = GroceryStore.shared
            if !groceries.hasLoaded { await groceries.load() }
            // A check from an older list is dropped.
            if let listID = message[WatchKeys.listID] as? String, listID != groceries.activeSnapshotID { return [:] }
            if let item = groceries.allItems.first(where: { $0.id == id }), groceries.isChecked(item) != checked {
                groceries.toggle(item)
            }
            return [:]
        case WatchKeys.pantry:
            guard let text = message[WatchKeys.text] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
            let lines = await tellPantry(text)
            let data = (try? JSONEncoder().encode(lines)) ?? Data()
            return [WatchKeys.lines: data]
        case WatchKeys.refresh:
            lastSent = nil
            await push()
            return [:]
        default:
            return [:]
        }
    }

    /// Tell the Pantry from the watch: the same parsing as the iPhone's, with the usual place
    /// for anything new (there's no room on the watch to ask), then saved.
    private func tellPantry(_ text: String) async -> [WatchPantryLine] {
        let kitchen = KitchenStore.shared
        let pantry = kitchen.pantry
        let spoken = await PantryVoiceParser.parse(text, itemNames: pantry.liveItems.map(\.name), containerNames: pantry.liveContainers.map(\.name))
        let proposals = kitchen.proposals(for: spoken).map { proposal -> PantryVoiceProposal in
            var proposal = proposal
            if proposal.question == .place {
                proposal.placeID = KitchenStore.defaultPlace(for: PantryNames.canonical(proposal.spoken.name), in: pantry)
            }
            proposal.question = nil
            return proposal
        }
        let amounts = PantryLedger.amounts(pantry)
        let lines = proposals.map { proposal -> WatchPantryLine in
            let described = kitchen.describe(proposal, amounts: amounts)
            let place = proposal.placeID.flatMap { id in pantry.livePlaces.first { $0.id == id }?.name }
            let detail = [described.change, place].compactMap { $0 }.joined(separator: " · ")
            return WatchPantryLine(name: proposal.name, change: described.change, detail: detail)
        }
        await kitchen.applyVoice(proposals)
        return lines
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.pushSoon() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switched to another watch: start again with it.
        WCSession.default.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastSent = nil
            self.pushSoon()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            let response = await self.handle(message)
            reply(response)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        nonisolated(unsafe) let message = message
        Task { @MainActor in _ = await self.handle(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        nonisolated(unsafe) let userInfo = userInfo
        Task { @MainActor in _ = await self.handle(userInfo) }
    }
}
