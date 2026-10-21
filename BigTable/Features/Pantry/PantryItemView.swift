import Charts
import SwiftUI
import UIKit

/// One thing in the pantry: how much, how it goes down over the planned meals until the next
/// shop, a stand-in already on the shelves when it runs short, the grocery list, Keep it
/// stocked, how the family buys it, and every change.
struct PantryItemView: View {
    let itemID: String

    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    @State private var kitchen = KitchenStore.shared
    @State private var showFix = false
    @State private var confirmRemove = false
    @State private var listing = false

    var body: some View {
        let snapshot = kitchen.pantrySnapshot()
        if let row = snapshot.row(itemID) {
            content(row, snapshot: snapshot)
        } else {
            ContentUnavailableView("Not in the pantry", systemImage: "cabinet")
        }
    }

    private func content(_ row: PantrySnapshot.Row, snapshot: PantrySnapshot) -> some View {
        let item = row.item
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if let place = row.place {
                        Label(place.name.uppercased(), systemImage: place.kind.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(place.color)
                    }
                    Text(item.name)
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.amountText)
                            .font(.title.weight(.bold))
                            .monospacedDigit()
                        if row.amount.isUnsure {
                            Text("a guess").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }

            if !row.savedFor.isEmpty {
                Section {
                    runway(row, shop: snapshot.nextShop)
                } header: {
                    HStack {
                        Text("Until your next shop")
                        Spacer()
                        Text(row.shortfall?.badge ?? "Lasts")
                            .foregroundStyle(row.shortfall == nil ? PantryColors.good : PantryColors.warn)
                    }
                }
            }

            if let shortfall = row.shortfall, let use = shortfall.use {
                swapSection(row, use: use, missing: shortfall.missing)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grocery list")
                        Text(row.onList ? "On it" : "Not on it")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(row.onList ? PantryColors.good : .secondary)
                    }
                    Spacer()
                    if !row.onList {
                        Button("Add") {
                            listing = true
                            Task {
                                await kitchen.addToGroceryList(item)
                                listing = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(.primary)
                        .disabled(listing)
                    }
                }
                Toggle(isOn: Binding(get: { item.keepStocked }, set: { on in
                    var next = item
                    next.keepStocked = on
                    kitchen.update(next)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep it stocked")
                        Text("Add it when it'll run out before you shop")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Kept in", selection: Binding(get: { item.placeID }, set: { place in
                    var next = item
                    next.placeID = place
                    kitchen.update(next)
                })) {
                    ForEach(snapshot.places) { place in
                        Text(place.name).tag(place.id)
                    }
                }
                .tint(.primary)
                if let container = row.container {
                    NavigationLink {
                        PantryContainersView(selected: container.id)
                    } label: {
                        LabeledContent("Container", value: container.name)
                    }
                }
            }

            Section("How you buy it") {
                if let usual = item.usualBuy {
                    LabeledContent("Usually", value: usual)
                }
                ForEach(history(item).prefix(8), id: \.id) { change in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(change))
                            Text(change.at.formatted(date: .abbreviated, time: .omitted))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(amountLabel(change, item: item))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Fix the Amount", systemImage: "pencil") { showFix = true }
                    .tint(.primary)
                Button("Remove from Pantry", systemImage: "trash", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFix) {
            PantryAmountSheet(item: item, current: row.amount.amount) { base in
                kitchen.setAmount(base, of: item)
            }
        }
        .confirmationDialog("Remove \(item.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                kitchen.removeFromPantry(item)
                dismiss()
            }
        } message: {
            Text("BigTable stops counting it. Buying it again puts it back.")
        }
    }

    // MARK: Runway

    private struct Point: Identifiable {
        var id: Int
        var at: Date
        var amount: Double
        var meal: String?
    }

    private func points(_ row: PantrySnapshot.Row) -> [Point] {
        var left = row.amount.amount
        var points = [Point(id: 0, at: .now, amount: left, meal: nil)]
        for (index, use) in row.savedFor.enumerated() {
            guard let need = use.amount, let day = ISODay.date(from: use.date) else { continue }
            let hour = use.slot == .breakfast ? 8 : (use.slot == .lunch ? 12 : 18)
            let at = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
            left -= need
            points.append(Point(id: index + 1, at: max(at, .now.addingTimeInterval(Double(index + 1) * 60)), amount: left, meal: use.mealTitle))
        }
        return points
    }

    private func runway(_ row: PantrySnapshot.Row, shop: Date) -> some View {
        let points = points(row)
        let item = row.item
        return VStack(alignment: .leading, spacing: 10) {
            Chart {
                RuleMark(y: .value("Empty", 0.0))
                    .foregroundStyle(Color(.systemGray3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                ForEach(points) { point in
                    LineMark(x: .value("When", point.at), y: .value("Left", point.amount))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Color.primary)
                    if point.meal != nil {
                        PointMark(x: .value("When", point.at), y: .value("Left", point.amount))
                            .foregroundStyle(point.amount < 0 ? accent : Color.primary)
                    }
                }
                if let last = points.last {
                    LineMark(x: .value("When", shop), y: .value("Left", last.amount))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Color.primary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(PantryUnits.display(amount, for: item)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            }
            .frame(height: 160)
            .accessibilityLabel(chartSummary(row))

            ForEach(row.savedFor.indices, id: \.self) { index in
                let use = row.savedFor[index]
                let short = row.shortfall?.use == use
                HStack {
                    Text(dayLabel(use))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(use.mealTitle)
                        .font(.subheadline.weight(short ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                    Text(use.amount.map { PantryUnits.display($0, for: item) } ?? "some")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(short ? PantryColors.warn : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func chartSummary(_ row: PantrySnapshot.Row) -> String {
        if let shortfall = row.shortfall, let use = shortfall.use {
            return "\(row.item.name) runs \(PantryUnits.display(shortfall.missing, for: row.item)) short at \(use.mealTitle)."
        }
        return "\(row.item.name) lasts until your next shop."
    }

    private func dayLabel(_ use: PantryLedger.PlannedUse) -> String {
        let day = ISODay.date(from: use.date)?.formatted(.dateTime.weekday(.abbreviated)) ?? use.date
        return "\(day) \(use.slot.label.lowercased())"
    }

    // MARK: Swap

    @ViewBuilder
    private func swapSection(_ row: PantrySnapshot.Row, use: PantryLedger.PlannedUse, missing: Double) -> some View {
        let amounts = PantryLedger.amounts(kitchen.pantry)
        let need = (row.savedFor.first { $0 == use }?.amount ?? missing)
        let swapped = kitchen.swap(for: row.item.canonical, slotKey: use.slotKey)
        if let swapped, let to = kitchen.pantry.items[swapped.toItemID] {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(use.mealTitle) uses \(to.name.lowercased())", systemImage: "arrow.triangle.swap")
                        .font(.headline)
                    Text("Just for this meal; the recipe didn't change.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Undo") { kitchen.setSwap(from: row.item.canonical, to: to, slotKey: use.slotKey, on: false) }
                    .tint(.primary)
            }
        } else if let stand = PantryLedger.swap(for: row.item.canonical, need: need, kind: row.item.kind, in: kitchen.pantry.liveItems, amounts: amounts) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Or skip buying more", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("You have \(PantryUnits.display(amounts[stand.id]?.amount ?? 0, for: stand)) of \(stand.name.lowercased()). Use it for \(use.mealTitle) and the \(row.item.name.lowercased()) lasts longer.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Use \(stand.name) for \(use.mealTitle)") {
                    kitchen.setSwap(from: row.item.canonical, to: stand, slotKey: use.slotKey, on: true)
                }
                .font(.body.weight(.semibold))
                .tint(.primary)
            }
        }
    }

    // MARK: History

    private func history(_ item: PantryItem) -> [PantryChange] {
        kitchen.pantry.changes.values.filter { $0.itemID == item.id }.sorted { $0.at > $1.at }
    }

    private func label(_ change: PantryChange) -> String {
        switch change.source {
        case .receipt: "Receipt in Suffice"
        case .checkoff: "Checked off the list"
        case .cooked: "Cooked"
        case .voice: "You said"
        case .check: "Quick check"
        case .edit: "Edited"
        case .refill: "Refilled"
        }
    }

    private func amountLabel(_ change: PantryChange, item: PantryItem) -> String {
        guard let amount = change.amount else { return change.kind == .use ? "some" : "" }
        switch change.kind {
        case .add: return "+" + PantryUnits.display(amount, for: item)
        case .use: return "−" + PantryUnits.display(amount, for: item)
        case .set: return amount == 0 ? "Out" : PantryUnits.display(amount, for: item)
        case .level: return "\(Int((amount * 100).rounded()))% full"
        }
    }
}

/// Fix the amount: a number and a unit.
struct PantryAmountSheet: View {
    let item: PantryItem
    let current: Double
    var onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var unit = ""

    private var units: [String] {
        switch item.kind {
        case .weight: ["lb", "oz"]
        case .volume: ["cup", "qt", "gal"]
        case .count: item.displayUnit == "dozen" ? ["", "dozen"] : [item.displayUnit]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount", text: $text)
                        .keyboardType(.decimalPad)
                        .font(.title2.weight(.semibold))
                    if units.count > 1 {
                        Picker("Unit", selection: $unit) {
                            ForEach(units, id: \.self) { unit in
                                Text(unit.isEmpty ? "each" : Ingredients.shortLabel(unit)).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } footer: {
                    Text("Now: \(PantryUnits.display(current, for: item))")
                }
                Section {
                    Button("We're Out", role: .destructive) {
                        onSave(0)
                        dismiss()
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Save") {
                        if let value = Ingredients.parseAmount(text), let base = PantryUnits.toBase(value, unit: unit, for: item) {
                            onSave(base)
                        }
                        dismiss()
                    }
                    .disabled(Ingredients.parseAmount(text) == nil)
                }
            }
            .onAppear { unit = item.displayUnit }
        }
        .presentationDetents([.medium])
    }
}
