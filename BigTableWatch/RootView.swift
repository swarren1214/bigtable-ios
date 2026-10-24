import SwiftUI

/// Three pages, one above the other (turn the Digital Crown): Tonight, Grocery, Tell the Pantry.
struct RootView: View {
    enum Page: Hashable { case tonight, grocery, pantry }

    @Environment(WatchStore.self) private var store
    @State private var page: Page = ScreenshotMode.page
    @State private var showsCook = false

    var body: some View {
        TabView(selection: $page) {
            NavigationStack {
                TonightView()
                    .navigationDestination(isPresented: $showsCook) { CookView(recipe: ScreenshotMode.fajitas) }
            }
            .tag(Page.tonight)
            NavigationStack { GroceryListView() }
                .tag(Page.grocery)
            NavigationStack { PantryView() }
                .tag(Page.pantry)
        }
        .tabViewStyle(.verticalPage)
        .task {
            // Screenshot mode's cooking screen: open the recipe once Tonight is up.
            guard ScreenshotMode.screen == .cook else { return }
            try? await Task.sleep(for: .seconds(1))
            showsCook = true
        }
        // The complications open the page they show.
        .onOpenURL { url in
            switch url.host() {
            case "grocery": page = .grocery
            case "pantry": page = .pantry
            default: page = .tonight
            }
        }
    }
}

/// The app's color fading into black behind a page, like the iPhone app's color header.
extension View {
    func bigTablePage() -> some View {
        containerBackground(WatchTheme.accent.gradient, for: .tabView)
    }
}

/// Shown until the iPhone has sent anything.
struct WaitingForPhone: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.title2)
                .accessibilityHidden(true)
            Text("Open BigTable on your iPhone")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Your plan and grocery list will show up here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
