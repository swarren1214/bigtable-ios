import SwiftUI
import UIKit

/// Put Away: a Suffice receipt's food lines, each turned into a pantry item and sorted by where
/// it goes. Tap a place to move something (BigTable remembers). Put Away adds them all, crosses
/// them off the grocery list, and can be undone.
struct ReceiptPutAwayView: View {
    let receipt: HearthReceipt

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var kitchen = KitchenStore.shared
    @State private var lines: [PutAwayLine] = []
    @State private var moved: Set<String> = []
    @State private var done = false

    var body: some View {
        NavigationStack {
            Group {
                if done { finished } else { form }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Put Away")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } }
            }
        }
        .task {
            if !GroceryStore.shared.hasLoaded { await GroceryStore.shared.load() }
            if lines.isEmpty { lines = kitchen.putAwayLines(for: receipt) }
        }
    }

    private var places: [PantryPlace] { kitchen.pantry.livePlaces }
    private var skipped: [HearthReceiptLine] { receipt.lines.filter { !$0.isFood } }
    private var crossedOff: Int { lines.reduce(0) { $0 + $1.listItemIDs.count } }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Put away your \(receipt.store) run")
                        .font(.system(.title, design: .serif, weight: .semibold))
                    Text("Suffice read the receipt on your \(DeviceName.current). BigTable sorted it by where things go. Tap a place to move something.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                HStack(spacing: 8) {
                    stat("\(lines.count)", "groceries to put away", .primary)
                    stat("\(crossedOff)", "crossed off your list", PantryColors.good)
                    stat("\(skipped.count)", "not food, skipped", .secondary)
                }

                ForEach(places) { place in
                    let mine = lines.filter { $0.placeID == place.id }
                    if !mine.isEmpty { group(place, mine) }
                }

                if !skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not food").font(.title3.weight(.bold)).padding(.horizontal, 4)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(skipped, id: \.self) { line in
                                receiptText(line)
                            }
                            Text("Left out of the pantry. They stay in Suffice.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 90)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                kitchen.putAway(receipt, lines: lines)
                withAnimation(.snappy) { done = true }
            } label: {
                Text("Put Away \(lines.count) Item\(lines.count == 1 ? "" : "s")")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(lines.isEmpty)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .sensoryFeedback(.success, trigger: done)
        }
    }

    private func stat(_ number: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(number).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func group(_ place: PantryPlace, _ mine: [PutAwayLine]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(place.name, systemImage: place.kind.symbol)
                    .font(.title3.weight(.bold))
                    .labelStyle(PantryPlaceLabelStyle(color: place.color))
                Spacer()
                Text("\(mine.count) item\(mine.count == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(mine.enumerated()), id: \.element.id) { index, line in
                    row(line)
                    if index < mine.count - 1 { Divider().padding(.leading, 16) }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
        }
    }

    private func row(_ line: PutAwayLine) -> some View {
        let place = places.first { $0.id == line.placeID }
        let wasMoved = moved.contains(line.id)
        return VStack(alignment: .leading, spacing: 6) {
            receiptText(line.line)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    let amount = quantity(line).map { " · " + $0 } ?? ""
                    Text("\(Text(line.name).fontWeight(.semibold))\(Text(amount).foregroundStyle(.secondary))")
                    let note = wasMoved ? "Moved · BigTable will remember" : line.note
                    if !note.isEmpty {
                        Text(note)
                            .font(.footnote.weight(!line.listItemIDs.isEmpty && !wasMoved ? .semibold : .regular))
                            .foregroundStyle(!line.listItemIDs.isEmpty && !wasMoved ? PantryColors.good : .secondary)
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    ForEach(places) { option in
                        Button(option.name, systemImage: option.kind.symbol) { move(line, to: option.id) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(place?.name ?? "Place")
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(place?.color ?? accent)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background((place?.color ?? accent).opacity(0.13), in: Capsule())
                } primaryAction: {
                    let index = places.firstIndex { $0.id == line.placeID } ?? 0
                    move(line, to: places[(index + 1) % max(places.count, 1)].id)
                }
                .accessibilityLabel("\(line.name) goes in the \(place?.name ?? "pantry"). Move it.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func receiptText(_ line: HearthReceiptLine) -> some View {
        HStack {
            Text(line.raw)
            Spacer()
            if let price = line.price { Text(price, format: .number.precision(.fractionLength(2))) }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private func quantity(_ line: PutAwayLine) -> String? {
        guard let amount = line.quantity else { return nil }
        let unit = PantryUnits.normalized(line.unit)
        if unit.isEmpty || unit == "each" { return Ingredients.formatAmount(amount) }
        return "\(Ingredients.formatAmount(amount)) \(Ingredients.shortLabel(unit))"
    }

    private func move(_ line: PutAwayLine, to placeID: String) {
        guard let index = lines.firstIndex(where: { $0.id == line.id }) else { return }
        withAnimation(.snappy) {
            lines[index].placeID = placeID
            moved.insert(line.id)
        }
    }

    private var finished: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(PantryColors.good)
                .frame(width: 88, height: 88)
                .background(PantryColors.good.opacity(0.16), in: Circle())
                .padding(.top, 40)
            Text("All put away")
                .font(.system(.title, design: .serif, weight: .semibold))
            VStack(spacing: 0) {
                let used = places.filter { place in lines.contains { $0.placeID == place.id } }
                ForEach(Array(used.enumerated()), id: \.element.id) { index, place in
                    HStack {
                        Text(place.name)
                        Spacer()
                        Text("+\(lines.filter { $0.placeID == place.id }.count)").fontWeight(.semibold).monospacedDigit()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    if index < used.count - 1 { Divider().padding(.leading, 16) }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
            Text(crossedOff > 0 ? "\(crossedOff) thing\(crossedOff == 1 ? "" : "s") crossed off your grocery list. Next time, BigTable puts each one where you put it today." : "Next time, BigTable puts each one where you put it today.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done").font(.headline).frame(maxWidth: .infinity).frame(height: 54)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            Button("Undo") {
                kitchen.undoPutAway(receipt)
                withAnimation(.snappy) { done = false }
            }
            .font(.headline)
        }
        .padding(24)
    }
}

/// A place's icon in its color, then its name.
struct PantryPlaceLabelStyle: LabelStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.15), in: .rect(cornerRadius: 8, style: .continuous))
            configuration.title
        }
    }
}
