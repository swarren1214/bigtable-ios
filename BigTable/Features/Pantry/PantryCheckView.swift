import SwiftUI
import UIKit

/// Quick check: up to six cards for what BigTable is least sure of, each with its guess and
/// why. Plenty, Low or Out; Low and Out go on the grocery list.
struct PantryCheckView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var kitchen = KitchenStore.shared
    @State private var cards: [PantrySnapshot.Row] = []
    @State private var index = 0
    @State private var answers: [(name: String, answer: PantryCheckAnswer)] = []
    @State private var loaded = false

    private var done: Bool { loaded && index >= cards.count }

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                } else if cards.isEmpty {
                    ContentUnavailableView("Nothing to check", systemImage: "checkmark.seal", description: Text("BigTable is fairly sure of everything right now."))
                } else if done {
                    summary
                } else {
                    deck
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Quick Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } }
                if !done, !cards.isEmpty {
                    ToolbarItem(placement: .confirmationAction) { Button("Skip") { withAnimation(.snappy) { index += 1 } } }
                }
            }
        }
        .task {
            guard !loaded else { return }
            if !GroceryStore.shared.hasLoaded { await GroceryStore.shared.load() }
            cards = kitchen.pantryCheckItems()
            loaded = true
        }
    }

    private var deck: some View {
        let row = cards[index]
        return VStack(spacing: 16) {
            VStack(spacing: 10) {
                HStack {
                    Text("Things BigTable isn't sure about").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(index + 1) of \(cards.count)").fontWeight(.semibold).monospacedDigit()
                }
                .font(.subheadline)
                HStack(spacing: 4) {
                    ForEach(cards.indices, id: \.self) { i in
                        Capsule()
                            .fill(i < index ? accent : (i == index ? accent.opacity(0.45) : Color(.systemFill)))
                            .frame(height: 5)
                    }
                }
            }
            .padding(.horizontal, 4)

            ZStack {
                ForEach([2, 1], id: \.self) { depth in
                    if index + depth < cards.count {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .scaleEffect(1 - CGFloat(depth) * 0.05, anchor: .bottom)
                            .offset(y: CGFloat(depth) * 12)
                            .opacity(depth == 1 ? 0.7 : 0.4)
                    }
                }
                card(row)
                    .id(row.id)
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .padding(16)
    }

    private func card(_ row: PantrySnapshot.Row) -> some View {
        let color = row.place?.color ?? .secondary
        return VStack(alignment: .leading, spacing: 14) {
            if let place = row.place {
                Label(place.name.uppercased(), systemImage: place.kind.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            Text(row.item.name)
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
            Spacer(minLength: 0)
            HStack(spacing: 22) {
                PantryJar(level: row.amount.level, color: accent.opacity(0.75), width: 96, height: 140)
                VStack(alignment: .leading, spacing: 4) {
                    Text("OUR GUESS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(guess(row)).font(.title2.weight(.bold))
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Text(why(row))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                answerButton("Plenty", .plenty, row, background: Color(.tertiarySystemFill), foreground: .primary)
                answerButton("Low", .low, row, background: PantryColors.warn.opacity(0.16), foreground: PantryColors.warn)
                answerButton("Out", .out, row, background: accent, foreground: .white)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
    }

    private func answerButton(_ title: String, _ answer: PantryCheckAnswer, _ row: PantrySnapshot.Row, background: Color, foreground: Color) -> some View {
        Button {
            answers.append((row.item.name, answer))
            Task { await kitchen.answerCheck(answer, for: row) }
            withAnimation(.snappy) { index += 1 }
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(background, in: .rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: index)
    }

    private func guess(_ row: PantrySnapshot.Row) -> String {
        let level = row.amount.level
        let words = level > 0.85 ? "Nearly full" : level > 0.6 ? "Most of it" : level > 0.4 ? "About half" : level > 0.2 ? "Under half" : "A little"
        return "\(words) · \(PantryUnits.display(row.amount.amount, for: row.item))"
    }

    private func why(_ row: PantrySnapshot.Row) -> String {
        let changes = kitchen.pantry.changes.values.filter { $0.itemID == row.item.id }.sorted { $0.at > $1.at }
        let cooked = changes.filter { $0.source == .cooked }.count
        var parts: [String] = []
        if cooked > 0 { parts.append("Cooking used some \(cooked) time\(cooked == 1 ? "" : "s") since you last said.") }
        if let added = row.amount.lastAdded { parts.append("Last bought \(added.formatted(.relative(presentation: .named))).") }
        if let next = row.savedFor.first { parts.append("\(next.mealTitle) needs it.") }
        return parts.isEmpty ? "It's been a while since anyone said how much there is." : parts.joined(separator: " ")
    }

    private var summary: some View {
        let added = answers.filter { $0.answer != .plenty }
        return VStack(spacing: 20) {
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(PantryColors.good)
                .frame(width: 88, height: 88)
                .background(PantryColors.good.opacity(0.16), in: Circle())
            Text("The pantry's current")
                .font(.system(.title, design: .serif, weight: .semibold))
            Text(added.isEmpty ? "Nothing needed adding to your list." : "\(added.count) \(added.count == 1 ? "thing is" : "things are") on your grocery list now.")
                .foregroundStyle(.secondary)
            if !added.isEmpty {
                VStack(spacing: 0) {
                    ForEach(added.indices, id: \.self) { i in
                        HStack {
                            Text(added[i].name)
                            Spacer()
                            Text(added[i].answer == .out ? "Out · on your list" : "Low · on your list")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PantryColors.good)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        if i < added.count - 1 { Divider().padding(.leading, 16) }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
            }
            Text("BigTable asks only when it's unsure, usually right before you plan a week.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done").font(.headline).frame(maxWidth: .infinity).frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .padding(24)
    }
}

/// Add something by hand: a name, how much, and where it's kept.
struct PantryAddView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kitchen = KitchenStore.shared
    @State var placeID: String
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("“4 lb white rice” or “2 dozen eggs”", text: $text)
                        .submitLabel(.done)
                        .onSubmit(save)
                    Picker("Kept in", selection: $placeID) {
                        ForEach(kitchen.pantry.livePlaces) { place in
                            Text(place.name).tag(place.id)
                        }
                    }
                } footer: {
                    Text("Type it however you like. Saying it works too: tap the mic on the Pantry.")
                }
            }
            .navigationTitle("Add to Pantry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark", action: save)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parsed = PantryVoiceParser.amountAndName(trimmed.lowercased())
        let name = parsed?.name ?? trimmed
        let item = kitchen.pantryItem(named: name, unit: parsed?.unit, placeID: placeID)
        if let parsed, let base = PantryUnits.toBase(parsed.amount, unit: parsed.unit, for: item) {
            kitchen.setAmount(base, of: item)
        } else {
            kitchen.record(.add, nil, of: item, source: .edit, confidence: 0.5)
            kitchen.pantryChanged()
        }
        dismiss()
    }
}
