import SwiftUI

/// The system Liquid Glass tab bar: Plan, Recipes, Grocery and Community, with recipe search as
/// the separate round search tab (as in Hearken and Suffice). Notifications and Profile live in
/// every tab's toolbar. On iPad it's a bar at the top that opens into a sidebar.
struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var recipesPath = NavigationPath()
    @State private var communityPath = NavigationPath()

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab(value: AppTab.plan) {
                NavigationStack { PlanView() }
            } label: {
                tabLabel("Plan", "calendar")
            }

            Tab(value: AppTab.recipes) {
                NavigationStack(path: $recipesPath) { RecipesView() }
            } label: {
                tabLabel("Recipes", "book.closed")
            }

            Tab(value: AppTab.grocery) {
                NavigationStack { GroceryView() }
            } label: {
                tabLabel("Grocery", "cart")
            }

            if AppConfig.socialEnabled {
                Tab(value: AppTab.community) {
                    NavigationStack(path: $communityPath) { CommunityView() }
                } label: {
                    tabLabel("Community", "person.2")
                }
            }

            Tab(value: AppTab.search, role: .search) {
                NavigationStack { RecipeSearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        // Debug: marketing screenshots (scripts/screenshots.sh). Does nothing otherwise.
        .screenshotStage(recipesPath: $recipesPath, communityPath: $communityPath)
    }

    /// Icon only in the iPhone tab bar (VoiceOver still reads the name); icon and name on iPad.
    @ViewBuilder
    private func tabLabel(_ title: String, _ systemImage: String) -> some View {
        if sizeClass == .regular {
            // The sidebar tints tab icons with the app's color; keep each icon the color of its
            // name instead (black in Light Mode, white in Dark Mode). See AGENT.md.
            Label { Text(title) } icon: { Image.menuIcon(systemImage) }
        } else {
            Image(systemName: systemImage)
                .accessibilityLabel(title)
        }
    }
}

extension View {
    /// The toolbar every tab shares: Ask BigTable (✨), the notifications bell (with the unread
    /// count) and the profile avatar. White over the color header; pass `overHeader: false` on
    /// a screen without one.
    func bigTableToolbar(overHeader: Bool = true) -> some View {
        modifier(BigTableToolbar(overHeader: overHeader))
    }
}

private struct BigTableToolbar: ViewModifier {
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var model
    var overHeader = true

    func body(content: Content) -> some View {
        content.toolbar {
            // Ask BigTable runs on the device's built-in AI, so it only shows where that's on.
            if AskEngine.isAvailable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.present(.ask)
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("Ask BigTable")
                    .tint(overHeader ? .white : nil)
                }
            }
            if AppConfig.socialEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.present(.notifications)
                    } label: {
                        Image(systemName: model.unreadCount > 0 ? "bell.badge" : "bell")
                    }
                    .badge(model.unreadCount)
                    .accessibilityLabel(model.unreadCount > 0 ? "Notifications, \(model.unreadCount) unread" : "Notifications")
                    .tint(overHeader ? .white : nil)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.present(.profile)
                } label: {
                    MemberAvatar(name: model.me?.myMember?.name ?? model.householdName, color: PersonColor.forIndex(0).color, url: ProfileAvatar.url(for: model.me?.myMember?.avatarUrl), size: 30, hearthName: model.me?.myMember?.name)
                }
                .accessibilityLabel("Profile and household")
            }
        }
    }
}
