import SwiftUI

/// One thing to buy: a round check in its aisle's color, the name, how much, which meals it's
/// for, and a Bulk tag for warehouse sizes. Tapping the row checks it off.
struct GroceryItemRow: View {
    var item: GroceryItem
    var isChecked: Bool
    var color: Color
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 12) {
                RoundCheck(isOn: isChecked, color: color, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.name)
                            .font(.body)
                            .strikethrough(isChecked, color: .secondary)
                            .foregroundStyle(isChecked ? .secondary : .primary)
                        if item.bulk {
                            TagLabel(text: "Bulk", color: color)
                        }
                    }
                    if let meals = GroceryFormat.meals(item.meals) {
                        Text(meals)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if !item.quantity.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(item.quantity)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .frame(maxWidth: 140, alignment: .trailing)
                }
            }
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: isChecked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isChecked ? "Marks it as still needed" : "Checks it off")
    }

    private var accessibilityText: String {
        var parts = [item.name]
        if !item.quantity.isEmpty { parts.append(item.quantity) }
        if item.bulk { parts.append("bulk") }
        if let meals = GroceryFormat.meals(item.meals) { parts.append(meals) }
        return parts.joined(separator: ", ")
    }
}

/// A section's header: its aisle symbol and color, the name, how many are left, and (when
/// there's more than one item) a button to check the whole section off.
struct GrocerySectionHeader: View {
    var section: GrocerySection
    var remaining: Int
    var onSetChecked: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: GroceryAisleStyle.symbol(section.name), color: GroceryAisleStyle.color(section.name), size: 28)
            Text(section.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
            Text(section.items.isEmpty ? "No items" : remaining == 0 ? "All done" : "\(remaining) left")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)
            Spacer()
            if !section.items.isEmpty {
                Menu {
                    Button("Check Off All", menuIcon: "checkmark.circle") { onSetChecked(true) }
                        .disabled(remaining == 0)
                    Button("Uncheck All", menuIcon: "circle") { onSetChecked(false) }
                        .disabled(remaining == section.items.count)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 32)
                        .contentShape(.rect)
                }
                .tint(.primary)
                .accessibilityLabel("\(section.name) options")
            }
        }
        .padding(.vertical, 2)
    }
}
