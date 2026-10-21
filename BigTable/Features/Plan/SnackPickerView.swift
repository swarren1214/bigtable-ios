import Foundation
import SwiftUI

/// Search packaged snacks (Open Food Facts) and pick one or more to add to a meal.
struct PlanSnackPickerView: View {
    /// "Tuesday lunch".
    var title: String
    var onAdd: ([PlannerSnackItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PlannerSnackItem] = []
    @State private var selected: [PlannerSnackItem] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var message: String?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedIDs: Set<String> { Set(selected.map(\.offId)) }

    var body: some View {
        NavigationStack {
            List {
                if !selected.isEmpty {
                    Section("Adding") {
                        ForEach(selected) { snack in
                            row(snack)
                        }
                    }
                }

                if trimmedQuery.count < 2 {
                    Section {
                        ContentUnavailableView(
                            "Search for a snack",
                            systemImage: SnackStyle.symbol,
                            description: Text("Try \u{201C}goldfish\u{201D}, \u{201C}granola bars\u{201D} or a brand.")
                        )
                    }
                    .listRowBackground(Color.clear)
                } else if isLoading && results.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }
                    .listRowBackground(Color.clear)
                } else if let message, results.isEmpty {
                    Section {
                        ContentUnavailableView("No snacks found", systemImage: "magnifyingglass", description: Text(message))
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section("Results") {
                        ForEach(results.filter { !selectedIDs.contains($0.offId) }) { snack in
                            row(snack)
                        }
                        if hasMore {
                            HStack {
                                Spacer()
                                if isLoadingMore {
                                    ProgressView()
                                } else {
                                    Button("Show More") { Task { await loadMore() } }
                                        .tint(.primary)
                                }
                                Spacer()
                            }
                            .onAppear { Task { await loadMore() } }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for a snack or food")
            .task(id: trimmedQuery) { await search() }
            .navigationTitle("Add Snacks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Add") {
                        onAdd(selected)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                    .accessibilityLabel(selected.count > 1 ? "Add \(selected.count) snacks to \(title)" : "Add to \(title)")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    Button {
                        onAdd(selected)
                        dismiss()
                    } label: {
                        Text(selected.count == 1 ? "Add 1 Snack" : "Add \(selected.count) Snacks")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func row(_ snack: PlannerSnackItem) -> some View {
        let isOn = selectedIDs.contains(snack.offId)
        return Button {
            toggle(snack)
        } label: {
            HStack(spacing: 12) {
                PlanSnackImage(url: snack.imageUrl, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snack.description)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    let details = [snack.brandOwner, snack.servingSize, snack.calories.map { "\(Int($0)) kcal" }].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(SnackStyle.color) : AnyShapeStyle(.tertiary))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func toggle(_ snack: PlannerSnackItem) {
        withAnimation(.snappy) {
            if let index = selected.firstIndex(where: { $0.offId == snack.offId }) {
                selected.remove(at: index)
            } else {
                selected.append(snack)
            }
        }
    }

    private func search() async {
        let text = trimmedQuery
        guard text.count >= 2 else {
            results = []
            message = nil
            hasMore = false
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await PlanOpenFoodFacts.search(text, page: 1)
            guard !Task.isCancelled else { return }
            results = found.results
            hasMore = found.hasMore
            page = 1
            message = found.results.isEmpty ? "Try a different name or brand." : nil
        } catch is CancellationError {
            return
        } catch {
            results = []
            hasMore = false
            message = FriendlyError.message(error)
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        let text = trimmedQuery
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await PlanOpenFoodFacts.search(text, page: page + 1)
            guard text == trimmedQuery else { return }
            let known = Set(results.map(\.offId))
            results += next.results.filter { !known.contains($0.offId) }
            hasMore = next.hasMore
            page += 1
        } catch {
            hasMore = false
        }
    }
}
