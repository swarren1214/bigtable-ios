import Foundation

/// A change Tell the Pantry will make, shown before it's saved.
struct PantryVoiceProposal: Identifiable, Hashable {
    enum Question: Hashable {
        /// A new item: where does it go?
        case place
        /// A container named for the first time: how much does it hold?
        case capacity
    }

    var id = UUID()
    var spoken: PantrySpoken
    var itemID: String?
    var name: String
    var containerID: String?
    var placeID: String?
    /// For a new container, once answered (in pounds or cups, or a count).
    var capacity: Double?
    var capacityUnit: String?
    var question: Question?

    var isNew: Bool { itemID == nil }
}

extension KitchenStore {
    /// What each thing said would change, with at most one question each.
    func proposals(for spoken: [PantrySpoken]) -> [PantryVoiceProposal] {
        let items = pantry.liveItems
        return spoken.map { said in
            var proposal = PantryVoiceProposal(spoken: said, name: KitchenStore.displayName(said.name))
            if said.kind == .level {
                if let container = pantryContainer(named: said.containerName ?? said.name) {
                    proposal.containerID = container.id
                    proposal.itemID = container.itemID
                    proposal.name = container.name
                    if container.capacity == nil { proposal.question = .capacity }
                } else {
                    proposal.question = .capacity
                }
                return proposal
            }
            if let item = PantryNames.match(said.name, in: items) {
                proposal.itemID = item.id
                proposal.name = item.name
                proposal.placeID = placeID(named: said.placeName) ?? item.placeID
            } else if said.kind == .set || said.kind == .add {
                proposal.placeID = placeID(named: said.placeName)
                if proposal.placeID == nil {
                    // Asked only when there's somewhere other than the usual three to choose.
                    if pantry.livePlaces.contains(where: { $0.kind == .other }) {
                        proposal.question = .place
                    } else {
                        proposal.placeID = KitchenStore.defaultPlace(for: PantryNames.canonical(said.name), in: pantry)
                    }
                }
            }
            return proposal
        }
    }

    func placeID(named name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        let places = pantry.livePlaces
        if let exact = places.first(where: { $0.name.lowercased() == name }) { return exact.id }
        if name.contains("freezer") { return PantryPlace.freezerID }
        if name.contains("fridge") { return PantryPlace.fridgeID }
        if name.contains("pantry") || name.contains("cupboard") { return PantryPlace.pantryID }
        return places.first { name.contains($0.name.lowercased()) }?.id
    }

    /// "4 lb · was 1 lb", "Out · added to your list", "≈ 3 lb · a third full".
    func describe(_ proposal: PantryVoiceProposal, amounts: [String: PantryAmount]) -> (change: String, was: String) {
        let item = proposal.itemID.flatMap { pantry.items[$0] }
        let before = item.flatMap { amounts[$0.id] }
        let wasText: String = {
            guard let item, let before, before.lastAdded != nil || before.lastSure != nil else { return "new" }
            return "was " + PantryUnits.display(before.amount, for: item)
        }()
        let said = proposal.spoken
        switch said.kind {
        case .out: return ("Out", wasText)
        case .low: return ("Low", wasText)
        case .level:
            let fraction = PantryVoiceParser.fractions.first { abs($0.1 - (said.level ?? 0)) < 0.02 }?.0 ?? "\(Int((said.level ?? 0) * 100))%"
            if let item, let container = proposal.containerID.flatMap({ pantry.containers[$0] }), let capacity = container.capacity ?? proposal.capacity {
                return ("≈ " + PantryUnits.display((said.level ?? 0) * capacity, for: item), fraction + " full")
            }
            return (fraction.prefix(1).uppercased() + fraction.dropFirst() + " full", wasText)
        case .set, .add:
            let amount = said.amount ?? 0
            let unitWord = said.unit.map { $0.isEmpty ? "" : " " + Ingredients.shortLabel($0) } ?? ""
            let text = (said.kind == .add ? "+" : "") + Ingredients.formatAmount(amount) + unitWord
            return (text, wasText)
        }
    }

    /// Saves every proposal: items made where needed, containers named, amounts changed, and
    /// anything out or low put on the grocery list.
    func applyVoice(_ proposals: [PantryVoiceProposal]) async {
        for proposal in proposals {
            let said = proposal.spoken
            switch said.kind {
            case .level:
                var container: PantryContainer
                if let id = proposal.containerID, let existing = pantry.containers[id] {
                    container = existing
                } else {
                    // A new container: it holds what it's named for ("the flour bin" → flour).
                    let contents = (said.containerName ?? said.name)
                        .replacingOccurrences(of: #"\s+(bin|bucket|canister|jar|container|tub|crock|tin)$"#, with: "", options: .regularExpression)
                    let item = pantryItem(named: contents, unit: proposal.capacityUnit ?? "lb", placeID: PantryPlace.pantryID)
                    container = PantryContainer(id: UUID().uuidString.lowercased(), name: KitchenStore.displayName(said.containerName ?? said.name), placeID: item.placeID, itemID: item.id, updatedAt: .now)
                }
                if container.capacity == nil, let capacity = proposal.capacity, let id = container.itemID, let item = pantry.items[id] {
                    container.capacity = PantryUnits.toBase(capacity, unit: proposal.capacityUnit, for: item) ?? capacity
                }
                container.updatedAt = .now
                put(pantryContainer: container)
                setLevel(said.level ?? 0, of: container)
            case .out:
                // Something the pantry didn't know yet is still out, and still goes on the list.
                let item = proposal.itemID.flatMap { pantry.items[$0] } ?? pantryItem(named: said.name, placeID: proposal.placeID)
                record(.set, 0, of: item, source: .voice, confidence: 1)
                await addToGroceryList(item)
            case .low:
                if let item = proposal.itemID.flatMap({ pantry.items[$0] }) {
                    let amounts = PantryLedger.amounts(pantry)
                    record(.set, (amounts[item.id]?.full ?? 0) * 0.2, of: item, source: .voice, confidence: 0.8)
                    await addToGroceryList(item)
                } else {
                    await addToGroceryList(pantryItem(named: said.name, placeID: proposal.placeID))
                }
            case .set, .add:
                var item = proposal.itemID.flatMap { pantry.items[$0] } ?? pantryItem(named: said.name, unit: said.unit, placeID: proposal.placeID)
                if let place = proposal.placeID, place != item.placeID {
                    item.placeID = place
                    update(item)
                }
                let base = said.amount.flatMap { PantryUnits.toBase($0, unit: said.unit, for: item) }
                record(said.kind == .add ? .add : .set, base, of: item, source: .voice, confidence: base == nil ? 0.6 : 1)
            }
        }
        pantryChanged()
    }
}
