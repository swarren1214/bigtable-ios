import Foundation
import SwiftUI
import UIKit
import UserNotifications

@main
struct BigTableApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var router = AppRouter.shared
    @State private var model = AppModel.shared
    @State private var subscriptions = Subscriptions.shared

    init() {
        // Debug: marketing screenshots (scripts/screenshots.sh). Does nothing otherwise.
        ScreenshotMode.prepareLaunch()
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(router)
                .environment(model)
                .environment(subscriptions)
                .task { await model.start() }
                .onOpenURL { url in router.open(url) }
        }
        .commands { BigTableCommands(router: router) }
    }
}

/// Push notifications: registers the device token with the API.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { try? await BigTableAPI.shared.registerPushToken(token, enabled: true) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Task { @MainActor in await AppModel.shared.refreshUnreadCount() }
        return [.banner, .badge, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { AppRouter.shared.present(.notifications) }
    }
}

/// Keyboard shortcuts for iPad (hold ⌘ to see them).
struct BigTableCommands: Commands {
    let router: AppRouter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recipe") { router.present(.newRecipe) }
                .keyboardShortcut("n")
            Button("Plan My Week") { router.present(.aiPlan) }
                .keyboardShortcut("k")
        }
        CommandMenu("Go") {
            Button("Plan") { router.tab = .plan }.keyboardShortcut("1")
            Button("Recipes") { router.tab = .recipes }.keyboardShortcut("2")
            Button("Grocery") { router.tab = .grocery }.keyboardShortcut("3")
            Button("Community") { router.tab = .community }.keyboardShortcut("4")
            Divider()
            Button("Notifications") { router.present(.notifications) }.keyboardShortcut("0")
            Button("Profile") { router.present(.profile) }.keyboardShortcut(",")
        }
    }
}

enum AppTab: Hashable {
    case plan, recipes, grocery, community, search
}

/// Sheets any screen can open.
enum AppSheet: Identifiable, Hashable {
    case paywall
    case profile
    case notifications
    case newRecipe
    case aiPlan
    case recipe(id: String, versionID: String?)
    case publicProfile(id: String)

    var id: String {
        switch self {
        case .paywall: "paywall"
        case .profile: "profile"
        case .notifications: "notifications"
        case .newRecipe: "newRecipe"
        case .aiPlan: "aiPlan"
        case .recipe(let id, let version): "recipe-\(id)-\(version ?? "")"
        case .publicProfile(let id): "profile-\(id)"
        }
    }
}

/// Which tab is showing and which sheet is up.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var tab: AppTab = .plan
    var sheet: AppSheet?
    /// The week the Plan tab shows, as its Sunday ("YYYY-MM-DD").
    var weekStart: String = ISODay.weekStart(containing: .now)

    func present(_ sheet: AppSheet) {
        self.sheet = sheet
    }

    /// bigtable://plan, bigtable://grocery, bigtable://recipes, bigtable://recipe/<id>,
    /// bigtable://auth (email links), and https://bigtableapp.com/r/<id> shared recipes.
    func open(_ url: URL) {
        if url.scheme == "bigtable", url.host() == "auth" {
            Task { await AppModel.shared.handleAuthRedirect(url) }
            return
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "https" {
            // The Expo app's share link: https://bigtableapp.com/recipe?id=<id>.
            if parts.first == "recipe", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
                present(.recipe(id: id, versionID: nil))
            } else if parts.first == "r" || parts.first == "recipes", parts.count > 1 {
                present(.recipe(id: parts[1], versionID: nil))
            }
            return
        }
        guard url.scheme == "bigtable" else { return }
        switch url.host() {
        case "grocery": tab = .grocery
        case "recipes": tab = .recipes
        case "recipe": if let id = parts.first { present(.recipe(id: id, versionID: nil)) }
        case "community": tab = .community
        case "notifications": present(.notifications)
        default: tab = .plan
        }
    }
}

/// Sign in, set up the household, then the tabs.
struct AppRoot: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.accentHex) private var accentHex = hexString(Brand.defaultAccentHex)
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceOption.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var showTutorial = false

    private var accent: Color { Color(hexString: accentHex) ?? Brand.defaultAccent }

    var body: some View {
        @Bindable var router = router
        @Bindable var model = model
        Group {
            switch model.phase {
            case .launching, .loading:
                LaunchView(error: model.loadError) { Task { await model.reload() } }
            case .signedOut:
                AuthView()
            case .needsHousehold:
                HouseholdSetupView()
            case .ready:
                RootTabView()
                    .sheet(item: $router.sheet) { sheet in
                        sheetContent(sheet)
                            .tint(accent)
                            .environment(\.accent, accent)
                    }
                    .sheet(isPresented: $showTutorial) {
                        TutorialView { model.markTutorialComplete() }
                            .tint(accent)
                            .environment(\.accent, accent)
                    }
                    .task {
                        // The tour is for the organizer setting things up, as in the Expo app.
                        showTutorial = model.isOrganizer && model.me?.profile?.tutorialComplete == false
                        await model.refreshUnreadCount()
                    }
            }
        }
        .tint(accent)
        .environment(\.accent, accent)
        .preferredColorScheme(AppearanceOption(rawValue: appearance)?.colorScheme)
        .animation(.smooth, value: model.phase)
        .sheet(isPresented: $model.needsNewPassword) { NewPasswordView().tint(accent) }
        .onChange(of: scenePhase) { _, phase in
            // Another Hearth app may have signed in, out, or as someone else meanwhile.
            if phase == .active {
                Task { await AuthClient.shared.followSharedSession() }
                HearthPhotoCache.shared.refreshIfChanged()
            }
            guard phase == .active, model.phase == .ready else { return }
            Task {
                await model.refreshUnreadCount()
                await Subscriptions.shared.refresh()
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .paywall: PaywallView()
        case .profile: NavigationStack { ProfileView() }
        case .notifications: NavigationStack { NotificationsView() }
        case .newRecipe: RecipeEditorView(mode: .create)
        case .aiPlan: AIPlanView()
        case .recipe(let id, let version): NavigationStack { RecipeDetailView(recipeID: id, versionID: version) }
        case .publicProfile(let id): NavigationStack { PublicProfileView(profileID: id, showsCloseButton: true) }
        }
    }
}

/// The first moment after launch, and what shows if the household can't be loaded.
struct LaunchView: View {
    var error: String?
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppIconBadge(size: 84)
            if let error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Try Again", action: retry)
                    .buttonStyle(.glassProminent)
                Button("Sign Out") { Task { await AppModel.shared.signOut() } }
                    .font(.footnote)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
