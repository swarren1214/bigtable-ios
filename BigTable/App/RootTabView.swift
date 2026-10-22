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

            // An explicit label, like the other tabs: icon only on iPhone (the default label
            // adds "Search"), and on iPad an icon in the text color rather than the app's color.
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { RecipeSearchView() }
            } label: {
                tabLabel("Search", "magnifyingglass")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        // The tour (HearthTour.swift): Welcome, then one step per tab. BigTableApp starts it for
        // a new organizer; Profile › Take the Tour runs it again.
        .hearthTour(app: .bigtable, steps: BigTableTour.steps, finishTitle: "Got It", autoStart: false) { step in
            router.tab = BigTableTour.tab(for: step)
        }
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
    /// The toolbar every tab shares: BigTable AI (✨), the notifications bell (with the unread
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

    /// Who can plan with AI (kids can't).
    private var canPlan: Bool { model.canUseAIPlan && model.canManagePlan }

    func body(content: Content) -> some View {
        content.toolbar {
            // BigTable AI, the app's one AI button: Plan the Week and Ask BigTable in one sheet.
            // Ask runs on the device's built-in AI; where that's off, ✨ opens the planner
            // straight away. Hidden for those who can do neither.
            if AskEngine.isAvailable || canPlan {
                ToolbarItem(placement: .topBarTrailing) {
                    // Every item has a title and a symbol, so the iPhone Duo's rail and the
                    // overflow menu can show it (the bar shows the symbol).
                    Button {
                        router.present(AskEngine.isAvailable ? .ask : .aiPlan)
                    } label: {
                        Label("BigTable AI", systemImage: "sparkles")
                    }
                    .tint(overHeader ? .white : nil)
                }
            }
            // Notifications are the Hearth account's: only when signed in.
            if AppConfig.socialEnabled && model.isSignedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.present(.notifications)
                    } label: {
                        Label("Notifications", systemImage: model.unreadCount > 0 ? "bell.badge" : "bell")
                    }
                    .badge(model.unreadCount)
                    .accessibilityLabel(model.unreadCount > 0 ? "Notifications, \(model.unreadCount) unread" : "Notifications")
                    .tint(overHeader ? .white : nil)
                }
            }
            // The profile photo, always last: the shared Hearth profile button (HearthProfile.swift),
            // the same in every Hearth app. BigTable presents Profile through its router.
            ToolbarItem(placement: .topBarTrailing) {
                HearthProfileButton(overHeader: overHeader) {
                    router.present(.profile)
                }
            }
        }
    }
}
