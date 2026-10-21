import SwiftUI
import UIKit

/// The containers the family has named ("the flour bin"), each drawn at how full it is, with
/// Empty to Full buttons, what it holds, and Refill from the bulk bag.
struct PantryContainersView: View {
    var selected: String?

    @Environment(\.accent) private var accent
    @State private var kitchen = KitchenStore.shared
    @State private var selection: String?
    @State private var showVoice = false

    private let levels: [(Double, String)] = [(0, "Empty"), (0.25, "¼"), (1.0 / 3, "⅓"), (0.5, "½"), (0.75, "¾"), (1, "Full")]

    var body: some View {
        let pantry = kitchen.pantry
        let containers = pantry.liveContainers.sorted { $0.name < $1.name }
        let amounts = PantryLedger.amounts(pantry)
        let current = containers.first { $0.id == (selection ?? selected) } ?? containers.first
        List {
            if let current, let itemID = current.itemID, let item = pantry.items[itemID] {
                Section {
                    hero(current, item: item, amount: amounts[itemID] ?? .unknown)
                        .listRowInsets(EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18))
                }
                Section {
                    capacityRow(current, item: item)
                    if let bulkID = current.refillFromItemID, let bulk = pantry.items[bulkID] {
                        Button {
                            kitchen.refill(current)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Filled it from the \(bulk.name.lowercased())")
                                Text("Sets it to full and takes what went in off the bag")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                    Picker("Refill from", selection: Binding(get: { current.refillFromItemID ?? "" }, set: { id in
                        var next = current
                        next.refillFromItemID = id.isEmpty ? nil : id
                        kitchen.saveContainer(next)
                    })) {
                        Text("Nothing").tag("")
                        ForEach(pantry.liveItems.filter { $0.id != itemID && $0.kind == item.kind }.sorted { $0.name < $1.name }) { other in
                            Text(other.name).tag(other.id)
                        }
                    }
                    .tint(.primary)
                }
            }

            Section {
                if containers.isEmpty {
                    Text("Say “the flour bin is about a third full” and BigTable asks once how much it holds. After that, a fraction is enough.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(containers) { container in
                    let item = container.itemID.flatMap { pantry.items[$0] }
                    let amount = container.itemID.flatMap { amounts[$0] } ?? .unknown
                    let level = container.capacity.map { $0 > 0 ? amount.amount / $0 : 0 } ?? amount.level
                    Button {
                        withAnimation(.snappy) { selection = container.id }
                    } label: {
                        HStack(spacing: 12) {
                            PantryJar(level: level, color: level <= 0.25 ? PantryColors.warn : accent, width: 22, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(container.name).foregroundStyle(.primary)
                                Text([pantry.livePlaces.first { $0.id == container.placeID }?.name, item?.name.lowercased(), container.capacity.flatMap { cap in item.map { "holds " + PantryUnits.display(cap, for: $0) } }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.map { amount.isOut ? "Empty" : "≈ " + PantryUnits.display(amount.amount, for: $0) } ?? "")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(container.id == current?.id ? accent.opacity(0.08) : nil)
                }
            } header: {
                Text("Your containers")
            } footer: {
                Text("Say “the rice bucket is half full” anytime. BigTable turns it into pounds.")
            }
        }
        .navigationTitle("Containers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Say how full", systemImage: "mic") { showVoice = true }
            }
        }
        .fullScreenCover(isPresented: $showVoice) { PantryVoiceView() }
    }

    private func hero(_ container: PantryContainer, item: PantryItem, amount: PantryAmount) -> some View {
        let level = container.capacity.map { $0 > 0 ? min(1, amount.amount / $0) : 0 } ?? amount.level
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 3)
                        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 20, style: .continuous))
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(accent.opacity(0.35))
                        .frame(height: max(0, 132 * level))
                        .padding(4)
                }
                .frame(width: 110, height: 140)
                .overlay(alignment: .top) {
                    Capsule().fill(Color(.systemGray3)).frame(width: 64, height: 12).offset(y: -10)
                }
                .animation(.snappy, value: level)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text((kitchen.pantry.livePlaces.first { $0.id == container.placeID }?.name ?? "").uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(container.name)
                        .font(.system(.title, design: .serif, weight: .semibold))
                    Text(amount.isOut ? "Empty" : "≈ " + PantryUnits.display(amount.amount, for: item))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    Text(item.name).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(levels, id: \.1) { option in
                    let on = abs(option.0 - level) < 0.04
                    Button {
                        kitchen.setLevel(option.0, of: container, source: .edit)
                    } label: {
                        Text(option.1)
                            .font(option.1.count > 1 ? .footnote.weight(.semibold) : .title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .foregroundStyle(on ? .white : .primary)
                            .background(on ? accent : Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.borderless)
                    .disabled(container.capacity == nil)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("How full is it?")
        }
    }

    private func capacityRow(_ container: PantryContainer, item: PantryItem) -> some View {
        let options: [Double] = switch item.kind {
        case .weight: [2, 4, 5, 10, 25, 50]
        case .volume: [4, 8, 16, 32]
        case .count: [6, 12, 24, 48]
        }
        let unit = item.kind == .volume ? "cup" : (item.kind == .weight ? "lb" : "")
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Holds")
                Spacer()
                Text(container.capacity.map { PantryUnits.display($0, for: item) } ?? "Not set")
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { value in
                        let base = PantryUnits.toBase(value, unit: unit, for: item) ?? value
                        let on = container.capacity.map { abs($0 - base) < 0.01 } ?? false
                        Button("\(Ingredients.formatAmount(value))\(unit.isEmpty ? "" : " " + unit)") {
                            var next = container
                            next.capacity = base
                            kitchen.saveContainer(next)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .foregroundStyle(on ? .white : .primary)
                        .background(on ? accent : Color(.tertiarySystemFill), in: Capsule())
                        .buttonStyle(.borderless)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 4)
    }
}
