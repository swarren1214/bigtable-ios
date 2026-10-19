import Foundation
import SwiftUI

/// Deleted Recipes (from Profile): recipes you deleted that were kept because they're still in
/// a meal plan or saved by someone. Restore puts one back in your drafts.
struct DeletedRecipesView: View {
    @State private var recipes: [RecipeSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var restoringID: String?
    @State private var restored: RecipeSummary?
    @State private var opened: RecipeDetailRoute?
    @State private var errorMessage: String?

    private let api = BigTableAPI.shared

    var body: some View {
        BigTableScreen(title: "Deleted Recipes") {
            if isLoading, recipes.isEmpty {
                LoadingCard(title: "Loading deleted recipes…")
            } else if let loadError, recipes.isEmpty {
                RetryCard(message: loadError) { Task { await load() } }
            } else if recipes.isEmpty {
                EmptyCard(
                    symbol: "trash",
                    title: "No deleted recipes",
                    message: "When you delete a recipe that's still in a meal plan or saved by others, it's kept here so you can restore it."
                )
            } else {
                Card {
                    Label {
                        Text("These recipes were deleted but kept because they're still in meal plans or saved by others. Restore one to put it back in your drafts.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                    }
                }

                CardList(items: recipes, inset: 84) { recipe in
                    RecipeRow(recipe: recipe, detail: tagLine(recipe)) {
                        restoreButton(recipe)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .alert("Recipe restored", isPresented: Binding(get: { restored != nil }, set: { if !$0 { restored = nil } }), presenting: restored) { recipe in
            Button("OK", role: .cancel) {}
            Button("View Recipe") {
                opened = RecipeDetailRoute(id: recipe.id, versionID: nil)
            }
        } message: { recipe in
            Text("“\(recipe.title)” is back in your drafts.")
        }
        .navigationDestination(item: $opened) { route in
            RecipeDetailView(recipeID: route.id, versionID: route.versionID, showsCloseButton: false)
        }
        .errorAlert($errorMessage, title: "Couldn't restore the recipe")
    }

    private func restoreButton(_ recipe: RecipeSummary) -> some View {
        Group {
            if restoringID == recipe.id {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                Button {
                    Task { await restore(recipe) }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(restoringID != nil)
                .accessibilityLabel("Restore \(recipe.title)")
            }
        }
    }

    private func tagLine(_ recipe: RecipeSummary) -> String {
        recipe.tags.prefix(3).map { RecipeQuickFilters.presetLabel(for: $0.lowercased()) ?? $0.uppercased() }.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        do {
            recipes = RecipeFormat.sortedByTitle(try await KitchenStore.shared.deletedRecipes().recipes)
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func restore(_ recipe: RecipeSummary) async {
        restoringID = recipe.id
        defer { restoringID = nil }
        do {
            try await KitchenStore.shared.restoreRecipe(recipe.id)
            withAnimation { recipes.removeAll { $0.id == recipe.id } }
            RecipeLibrary.shared.changed()
            restored = recipe
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
