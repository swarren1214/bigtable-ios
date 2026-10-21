import Foundation
import SwiftUI

/// The Recipes tab: every recipe you can cook (All), the ones you wrote (Mine) and the ones you
/// hearted (Favorites), with search, quick filters, and a grid of cards that loads more as you
/// scroll. + starts a new recipe.
struct RecipesView: View {
    @Environment(AppRouter.self) private var router
    @State private var store = RecipeStore()

    var body: some View {
        BigTableScreen(title: "Recipes") {
            Picker("Recipes", selection: $store.collection) {
                ForEach(RecipeCollection.allCases) { collection in
                    Text(collection.label).tag(collection)
                }
            }
            .pickerStyle(.segmented)

            RecipeQuickFilterBar(selection: $store.quickFilter)
                .hearthTourTarget(BigTableTour.recipes)

            RecipeLibraryResults(store: store, emptyState: emptyState)
        }
        .searchable(text: $store.query, prompt: "Search recipes")
        .refreshable {
            await KitchenStore.shared.syncNow()
            await store.reload()
        }
        // The family changed something on another phone.
        .onChange(of: KitchenStore.shared.revision) { Task { await store.reload() } }
        .onChange(of: store.collection) { Task { await store.reload() } }
        .onChange(of: store.quickFilter) { Task { await store.reload() } }
        .onChange(of: store.query) { store.queryChanged() }
        .task { await store.loadIfNeeded() }
        .navigationDestination(for: RecipeDetailRoute.self) { route in
            RecipeDetailView(recipeID: route.id, versionID: route.versionID, showsCloseButton: false)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Group {
                    Button("New Recipe", systemImage: "plus") {
                        router.present(.newRecipe)
                    }
                }
                // White over the color header.
                .tint(.white)
            }
        }
        .bigTableToolbar()
    }

    private var emptyState: EmptyCard {
        let searching = !store.query.recipeTrimmed.isEmpty
        if store.quickFilter != RecipeQuickFilters.all, !searching {
            return EmptyCard(symbol: "line.3.horizontal.decrease.circle", title: "No \(store.quickFilter) recipes", message: "Try another quick filter.")
        }
        switch store.collection {
        case .mine where !searching:
            return EmptyCard(symbol: "frying.pan", title: "You haven't written any recipes yet", message: "Tap + to add your first recipe.")
        case .favorites where !searching:
            return EmptyCard(symbol: "heart", title: "No favorites yet", message: "Tap the heart on any recipe to keep it here.")
        default:
            return searching
                ? EmptyCard(symbol: "magnifyingglass", title: "No results", message: "Try a different ingredient or recipe name.")
                : EmptyCard(symbol: "book.closed", title: "No recipes found", message: "Try another search.")
        }
    }
}

/// The loading, error, empty and grid states of a recipe list, with the next-page spinner and
/// the end-of-library note. Shared by the Recipes and Search tabs.
struct RecipeLibraryResults: View {
    var store: RecipeStore
    var emptyState: EmptyCard

    var body: some View {
        if store.recipes.isEmpty {
            if store.isLoading || !store.hasLoaded && store.loadError == nil {
                LoadingCard(title: "Loading recipes…")
            } else if let error = store.loadError {
                RetryCard(message: error) { Task { await store.reload() } }
            } else {
                emptyState
            }
        } else {
            RecipeGrid(recipes: store.recipes) { recipe in
                store.loadMoreIfNeeded(after: recipe)
            }
            .opacity(store.isLoading ? 0.6 : 1)
            .animation(.smooth, value: store.isLoading)

            if store.isLoadingMore {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading more recipes…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else if store.canPaginate, !store.hasMore, store.hasLoaded {
                Text("That's every recipe in the library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else if let error = store.loadError {
                Button("Couldn't load more. Try again.") { Task { await store.loadMore() } }
                    .font(.footnote)
                    .tint(.primary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHint(error)
            }
        }
    }
}
