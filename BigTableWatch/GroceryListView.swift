import SwiftUI

/// The grocery list, aisle by aisle, for shopping with the phone in a pocket: tap to check off
/// (it reaches the phone and the family's list, and the pantry, as on the iPhone).
struct GroceryListView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        Group {
            if let grocery = store.snapshot.grocery, grocery.total > 0 {
                List {
                    Section {
                        Text(grocery.remaining == 0 ? "All done" : "\(grocery.remaining) left of \(grocery.total)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(grocery.sections) { section in
                        let left = section.items.filter { !grocery.isChecked($0) }.count
                        Section {
                            // What's left first; checked items sink to the bottom of their aisle.
                            ForEach(section.items.sorted { !grocery.isChecked($0) && grocery.isChecked($1) }) { item in
                                Button {
                                    store.toggle(item)
                                } label: {
                                    GroceryRow(item: item, checked: grocery.isChecked(item))
                                }
                            }
                        } header: {
                            HStack {
                                Label(section.name, systemImage: section.icon)
                                Spacer()
                                Text(left == 0 ? "Done" : "\(left) left")
                            }
                        }
                    }
                }
            } else if store.hasData {
                ScrollView {
                    VStack(spacing: 6) {
                        Image(systemName: "cart")
                            .font(.title2)
                            .accessibilityHidden(true)
                        Text("No grocery list")
                            .font(.headline)
                        Text("Make one from your plan in BigTable on your iPhone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } else {
                ScrollView { WaitingForPhone() }
            }
        }
        .navigationTitle("Grocery")
        .bigTablePage()
    }
}

private struct GroceryRow: View {
    let item: WatchGroceryItem
    let checked: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if checked {
                    Circle().fill(WatchTheme.accent)
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 2)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .strikethrough(checked)
                    .lineLimit(2)
                if let note = item.note, !checked {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(checked ? .secondary : .primary)
            Spacer(minLength: 4)
            if !item.quantity.isEmpty {
                Text(item.quantity)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
