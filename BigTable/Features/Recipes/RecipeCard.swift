import Foundation
import SwiftUI
import UIKit

/// Where a recipe card leads: its detail, at a particular version when one was pinned.
nonisolated struct RecipeDetailRoute: Hashable, Identifiable, Sendable {
    var id: String
    var versionID: String?
}

/// A recipe in the library grid: its photo, name, time and servings, who shared it, its likes,
/// and (for your own recipes) whether it's a draft or published.
struct RecipeCard: View {
    var recipe: RecipeSummary
    var isOwned: Bool

    private var isOthersPublished: Bool {
        recipe.status == .published && !isOwned && recipe.createdByProfileId != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { RecipePhoto(url: recipe.imageUrl, cornerRadius: 0, symbolSize: 30) }
                .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                let facts = RecipeFormat.facts(prepMinutes: recipe.prepMinutes, cookMinutes: recipe.cookMinutes, baseServings: recipe.baseServings, sourceName: recipe.sourceName, difficulty: nil, likeCount: nil)
                if !facts.isEmpty {
                    Text(facts)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                badges

                if isOthersPublished {
                    RecipeCreatorByline(name: recipe.creatorName, avatarURL: recipe.creatorAvatarUrl, profileID: recipe.createdByProfileId)
                        .padding(.top, 2)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .contentShape(.rect(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badges: some View {
        let showsLikes = (recipe.likeCount ?? 0) > 0
        let showsStatus = isOwned && recipe.status != nil && recipe.status != .removed
        let showsUpdate = recipe.hasUpdateAvailable == true
        if showsLikes || showsStatus || showsUpdate {
            HStack(spacing: 6) {
                if showsStatus, let status = recipe.status {
                    RecipeLifecycleBadge(status: status)
                }
                if showsUpdate {
                    TagLabel(text: "Update available", color: .orange)
                }
                if showsLikes {
                    Label("\(recipe.likeCount ?? 0)", systemImage: recipe.isLiked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("\(recipe.likeCount ?? 0) likes")
                }
            }
        }
    }
}

/// Draft, Published, Unpublished or Removed, on your own recipes.
struct RecipeLifecycleBadge: View {
    var status: RecipeStatus

    var body: some View {
        TagLabel(text: Self.label(status), color: Self.color(status))
    }

    static func label(_ status: RecipeStatus) -> String {
        switch status {
        case .draft: "Draft"
        case .published: "Published"
        case .unpublished: "Unpublished"
        case .removed: "Removed"
        }
    }

    static func color(_ status: RecipeStatus) -> Color {
        switch status {
        case .draft: Color(.systemGray)
        case .published: Color(hex: 0x1E9E6A)
        case .unpublished: Color(hex: 0xC77700)
        case .removed: Color(hex: 0xD93B30)
        }
    }
}

/// "By the Carter Family", with their avatar, on someone else's published recipe.
struct RecipeCreatorByline: View {
    var name: String?
    var avatarURL: String?
    var profileID: String?

    private var displayName: String {
        let trimmed = name?.recipeTrimmed ?? ""
        return trimmed.isEmpty ? "BigTable creator" : trimmed
    }

    var body: some View {
        HStack(spacing: 6) {
            MemberAvatar(name: displayName, color: PersonColor.forKey(profileID ?? displayName).color, url: avatarURL, size: 20)
            Text(displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The heart on a recipe card: adds it to or removes it from Favorites.
struct RecipeFavoriteButton: View {
    var recipe: RecipeSummary
    var onError: (String) -> Void
    @State private var pulse = 0

    var body: some View {
        Button {
            pulse += 1
            let next = !recipe.isFavorite
            Task {
                do {
                    try await RecipeLibrary.shared.setFavorite(id: recipe.id, saved: next)
                } catch {
                    onError(FriendlyError.message(error))
                }
            }
        } label: {
            Image(systemName: recipe.isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(recipe.isFavorite ? Color.red : Color.primary)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: pulse)
        .accessibilityLabel(recipe.isFavorite ? "Remove \(recipe.title) from favorites" : "Add \(recipe.title) to favorites")
    }
}

/// The library's adaptive grid of cards (two across on iPhone, more on iPad), each opening
/// the recipe, with its heart on top.
struct RecipeGrid: View {
    var recipes: [RecipeSummary]
    var onCardAppear: (RecipeSummary) -> Void = { _ in }
    @State private var errorMessage: String?

    /// The grid's width. Columns come in even numbers (2 on a phone, 4 or 6 wider), so on a
    /// partly folded iPhone Duo the fold falls between cards, never through one.
    @State private var width: CGFloat = 0

    private var columns: [GridItem] {
        let count = HearthEvenColumns.count(for: width, minimumCellWidth: 158)
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(recipes) { recipe in
                NavigationLink(value: RecipeDetailRoute(id: recipe.id, versionID: nil)) {
                    RecipeCard(recipe: recipe, isOwned: RecipeFormat.isOwned(recipe))
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    RecipeFavoriteButton(recipe: recipe) { errorMessage = $0 }
                        .padding(2)
                }
                .onAppear { onCardAppear(recipe) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .errorAlert($errorMessage, title: "Couldn't update favorites")
    }
}

/// The horizontal row of quick-filter chips (Breakfast, Chicken, Vegetarian…).
struct RecipeQuickFilterBar: View {
    @Binding var selection: String
    @Environment(\.accent) private var accent

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RecipeQuickFilters.values, id: \.self) { filter in
                    Chip(title: filter, color: accent, isOn: selection == filter, showsDot: false) {
                        selection = filter
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

/// A compact row for lists (the picker, Deleted Recipes): thumbnail, title and facts.
struct RecipeRow<Trailing: View>: View {
    var recipe: RecipeSummary
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            RecipePhoto(url: recipe.imageUrl, cornerRadius: 12, symbolSize: 18)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(2)
                let line = detail ?? RecipeFormat.facts(recipe)
                if !line.isEmpty {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .contentShape(.rect)
    }
}
