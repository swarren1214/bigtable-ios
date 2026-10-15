import Foundation
import SwiftUI

/// The round Search tab: find any recipe you can cook by name, or browse by tag. Results open
/// the recipe.
struct RecipeSearchView: View {
    @Environment(\.accent) private var accent
    @State private var store = RecipeStore(collection: .all)

    private var isBrowsing: Bool {
        store.query.recipeTrimmed.isEmpty && store.quickFilter == RecipeQuickFilters.all
    }

    var body: some View {
        BigTableScreen(title: "Search") {
            if isBrowsing {
                SectionTitle("Browse by tag")
                FlowLayout(spacing: 8) {
                    ForEach(RecipeQuickFilters.tags, id: \.self) { tag in
                        Chip(title: tag, color: accent, isOn: false, showsDot: false) {
                            store.quickFilter = tag
                        }
                    }
                }
                SectionTitle("All recipes")
            } else if store.quickFilter != RecipeQuickFilters.all {
                HStack {
                    Chip(title: store.quickFilter, color: accent, isOn: true, showsDot: false) {
                        store.quickFilter = RecipeQuickFilters.all
                    }
                    .accessibilityHint("Removes this filter")
                    Spacer()
                    Button("Clear") { store.quickFilter = RecipeQuickFilters.all }
                        .font(.subheadline)
                }
            }

            RecipeLibraryResults(
                store: store,
                emptyState: EmptyCard(symbol: "magnifyingglass", title: "No results", message: "Try a different ingredient, recipe name or tag.")
            )
        }
        .searchable(text: $store.query, prompt: "Recipes")
        .refreshable { await store.reload() }
        .onChange(of: store.quickFilter) { Task { await store.reload() } }
        .onChange(of: store.query) { store.queryChanged() }
        .task { await store.loadIfNeeded() }
        .navigationDestination(for: RecipeDetailRoute.self) { route in
            RecipeDetailView(recipeID: route.id, versionID: route.versionID, showsCloseButton: false)
        }
        .bigTableToolbar()
    }
}
