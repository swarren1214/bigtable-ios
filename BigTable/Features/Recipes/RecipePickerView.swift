import Foundation
import SwiftUI

/// Choose a recipe (for a meal on the plan): search, filter, switch between All, Mine and
/// Favorites, and tap one to pick it. Comes with its own navigation bar and Cancel.
struct RecipePickerView: View {
    var onPick: (RecipeSummary) -> Void

    init(onPick: @escaping (RecipeSummary) -> Void) {
        self.onPick = onPick
    }

    @Environment(\.dismiss) private var dismiss
    @State private var store = RecipeStore(collection: .all, pageSize: 12)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Recipes", selection: $store.collection) {
                            ForEach(RecipeCollection.allCases) { collection in
                                Text(collection.label).tag(collection)
                            }
                        }
                        .pickerStyle(.segmented)
                        RecipeQuickFilterBar(selection: $store.quickFilter)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }

                Section {
                    results
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $store.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search recipes")
            .navigationTitle("Choose a Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .refreshable { await store.reload() }
            .onChange(of: store.collection) { Task { await store.reload() } }
            .onChange(of: store.quickFilter) { Task { await store.reload() } }
            .onChange(of: store.query) { store.queryChanged() }
            .task { await store.loadIfNeeded() }
        }
    }

    @ViewBuilder
    private var results: some View {
        if store.recipes.isEmpty {
            if store.isLoading || !store.hasLoaded && store.loadError == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading recipes…").foregroundStyle(.secondary)
                }
            } else if let error = store.loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await store.reload() } }
                }
            } else {
                ContentUnavailableView {
                    Label("No recipes found", systemImage: "magnifyingglass")
                } description: {
                    Text(emptyMessage)
                }
            }
        } else {
            ForEach(store.recipes) { recipe in
                Button {
                    onPick(recipe)
                    dismiss()
                } label: {
                    RecipeRow(recipe: recipe) {
                        if recipe.isFavorite {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.red)
                                .accessibilityLabel("Favorite")
                        }
                    }
                }
                .buttonStyle(.plain)
                .onAppear { store.loadMoreIfNeeded(after: recipe) }
            }
            if store.isLoadingMore {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading more recipes…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var emptyMessage: String {
        switch store.collection {
        case .mine where store.query.recipeTrimmed.isEmpty && store.quickFilter == RecipeQuickFilters.all:
            "You haven't written any recipes yet."
        case .favorites where store.query.recipeTrimmed.isEmpty && store.quickFilter == RecipeQuickFilters.all:
            "Heart a recipe to find it here."
        default:
            "Try another filter or search."
        }
    }
}
