import SwiftUI

/// The household's last five grocery lists: when each was made, how many items, the cost
/// estimate and where it came from. The organizer can make an older list the active one
/// again. A Pro feature.
struct GroceryHistoryView: View {
    var store: GroceryStore

    init(store: GroceryStore) {
        self.store = store
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var confirming: GrocerySnapshot?

    var body: some View {
        NavigationStack {
            List {
                if store.snapshots.isEmpty {
                    ContentUnavailableView("No lists yet", systemImage: "clock.arrow.circlepath", description: Text("Your last five grocery lists appear here."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(store.snapshots) { snapshot in
                            row(snapshot)
                        }
                    } footer: {
                        Text(model.isOrganizer ? "BigTable keeps your last five lists. Restoring one makes it your current list again, checks and all." : "BigTable keeps the household's last five lists. Your organizer can restore one.")
                    }
                }
            }
            .navigationTitle("List History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .overlay {
                if store.isRestoring {
                    ProgressView("Restoring…")
                        .padding(24)
                        .glassEffect(in: .rect(cornerRadius: 22))
                }
            }
            .confirmationDialog(
                "Restore this list?",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { snapshot in
                Button("Restore List") {
                    Task {
                        await store.restore(snapshot)
                        dismiss()
                    }
                }
            } message: { _ in
                Text("It replaces your current list. The current list stays in History.")
            }
        }
    }

    @ViewBuilder
    private func row(_ snapshot: GrocerySnapshot) -> some View {
        let isActive = snapshot.id == store.activeSnapshotID
        let checked = snapshot.checks.values.filter { $0 }.count
        HStack(spacing: 14) {
            IconTile(symbol: GroceryFormat.sourceSymbol(snapshot.source), color: isActive ? .green : .secondary, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title(snapshot))
                        .font(.headline)
                    if isActive {
                        TagLabel(text: "Current", color: .green)
                    }
                }
                Text(detail(snapshot, checked: checked))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(GroceryFormat.sourceLabel(snapshot.source) + " · " + relativeTime(snapshot.generatedAtIso))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if model.isOrganizer, !isActive {
                Button("Restore") { confirming = snapshot }
                    .buttonStyle(.glass)
                    .disabled(store.isRestoring)
                    .accessibilityLabel("Restore the list from \(title(snapshot))")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func title(_ snapshot: GrocerySnapshot) -> String {
        if let range = GroceryRangeMemory.range(for: snapshot.id) {
            return GroceryDates.label(start: range.start, end: range.end)
        }
        guard let date = ISODay.timestamp(snapshot.generatedAtIso) else { return "Grocery list" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func detail(_ snapshot: GrocerySnapshot, checked: Int) -> String {
        var parts = ["\(snapshot.itemCount) \(snapshot.itemCount == 1 ? "item" : "items")"]
        if checked > 0 { parts.append("\(checked) checked") }
        if snapshot.estimatedCost > 0 { parts.append("about \(GroceryFormat.cost(snapshot.estimatedCost))") }
        return parts.joined(separator: " · ")
    }
}
