import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications

@main
struct BigTableApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var router = AppRouter.shared
    @State private var model = AppModel.shared

    init() {
        // Debug: marketing screenshots (scripts/screenshots.sh). Does nothing otherwise.
        ScreenshotMode.prepareLaunch()
        // Alerts use the system label color rather than the accent. Destructive buttons stay red.
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = .label
        // Appearance moved to the shared Hearth Profile; keep the choice made under the old key.
        HearthAppearance.adopt(legacyKey: SettingsKey.legacyAppearance)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(router)
                .environment(model)
                .task { await model.start() }
                // Household invitations (HearthInviteLink) open the join sheet.
                .onOpenURL { url in
                    if HearthInviteLink.open(url) { return }
                    router.open(url)
                }
        }
        .commands { BigTableCommands(router: router) }
    }
}

/// Push notifications: registers the device token with the API, and hears CloudKit's silent
/// pushes when the family's kitchen or household changes.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Always, whatever the notification setting: CloudKit's silent pushes are how this
        // device hears that someone else changed the kitchen, and they need no permission.
        // Whether BigTable's own notifications reach this device is the API token's business
        // (`didRegisterForRemoteNotificationsWithDeviceToken`).
        if !ScreenshotMode.isOn { application.registerForRemoteNotifications() }
        return true
    }

    /// CloudKit's silent push: someone changed the kitchen or the household.
    nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await HearthHouseholdStore.shared.catchUp()
        return .newData
    }

    /// Household invitations (iCloud) arrive through the scene delegate.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = HearthHouseholdSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            // BigTable's own notifications only when they're on and allowed (registering
            // happens at every launch now, for CloudKit's pushes).
            guard AppConfig.pushEnabled, !UserDefaults.standard.bool(forKey: SettingsKey.pushDisabled) else { return }
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional || status == .ephemeral else { return }
            try? await BigTableAPI.shared.registerPushToken(token, enabled: true)
        }
    }

    // Completion-handler forms: they must be called on the main thread, which an async
    // delegate method doesn't promise (that crashed Caloma whenever a notification was tapped).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in await AppModel.shared.refreshUnreadCount() }
        completionHandler([.banner, .badge, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // Cook Mode's kitchen timer (CookSession) is local, not an inbox notification: just open the app.
        let isTimer = response.notification.request.identifier == "bigtable.cook-timer"
        let done = MainThreadCompletion<Void> { _ in completionHandler() }
        DispatchQueue.main.async {
            defer { done.run(()) }
            guard !isTimer else { return }
            MainActor.assumeIsolated { AppRouter.shared.present(.notifications) }
        }
    }
}

/// A notification delegate's completion handler, carried to the main queue to be called there.
private nonisolated final class MainThreadCompletion<Value>: @unchecked Sendable {
    private let completion: (Value) -> Void
    init(_ completion: @escaping (Value) -> Void) { self.completion = completion }
    func run(_ value: Value) { completion(value) }
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
    case profile
    case notifications
    case newRecipe
    case aiPlan
    case recipe(id: String, versionID: String?)
    case publicProfile(id: String)
    /// BigTable AI (the ✨ button): Plan the Week and Ask BigTable.
    case ask

    var id: String {
        switch self {
        case .profile: "profile"
        case .notifications: "notifications"
        case .newRecipe: "newRecipe"
        case .aiPlan: "aiPlan"
        case .recipe(let id, let version): "recipe-\(id)-\(version ?? "")"
        case .publicProfile(let id): "profile-\(id)"
        case .ask: "ask"
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

    /// bigtable://plan, bigtable://grocery, bigtable://recipes, bigtable://recipe/<id>, and
    /// https://bigtableapp.com/r/<id> shared recipes. (bigtable://auth email links are gone with
    /// email sign-in.)
    func open(_ url: URL) {
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
    /// Shows onboarding once the phase is known, if this install needs it.
    private func checkOnboarding() {
        guard model.phase != .launching, !showsOnboarding, !onboardingCheckRunning else { return }
        onboardingCheckRunning = true
        Task {
            let needed = await BigTableOnboarding.isNeededAfterCheckingCloud(model)
            onboardingCheckRunning = false
            if needed, model.phase != .launching { showsOnboarding = true }
        }
    }

    /// Onboarding is up, but the family or this person turned out to have done it already
    /// somewhere else: it closes. (Not for what they've added here meanwhile.)
    private func recheckOpenOnboarding() {
        guard showsOnboarding, BigTableOnboarding.isDoneElsewhere else { return }
        BigTableOnboarding.skipHere(model)
        showsOnboarding = false
    }

    @State private var onboardingCheckRunning = false
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var purchases = HearthPurchases.shared
    /// First run on this install (BigTableOnboarding.swift).
    @State private var showsOnboarding = false

    private var accent: Color { Brand.defaultAccent }

    var body: some View {
        @Bindable var router = router
        @Bindable var model = model
        Group {
            switch model.phase {
            case .launching:
                LaunchView()
            case .needsHousehold:
                KitchenSetupView()
            case .ready:
                RootTabView()
                    .sheet(item: $router.sheet) { sheet in
                        sheetContent(sheet)
                            .tint(accent)
                            .environment(\.accent, accent)
                    }
                    .task {
                        // The tour is for the organizer setting things up, once per account.
                        // Onboarding offers it itself (and marks it seen), so not while it's up.
                        if model.isOrganizer && model.me?.profile?.tutorialComplete != true && !ScreenshotMode.isOn {
                            try? await Task.sleep(for: .milliseconds(600))
                            if !showsOnboarding && UserDefaults.standard.bool(forKey: BigTableOnboarding.doneKey) {
                                HearthTour.shared.startIfNew()
                                model.markTutorialComplete()
                            }
                        }
                        await model.refreshUnreadCount()
                    }
            }
        }
        .tint(accent)
        .environment(\.accent, accent)
        // iPhone Duo: reads the pose (closed, open, Book, Laptop) for the whole window, outside
        // the tab view, and passes it down as `\.hearthDuoPose` (HearthDuo.swift).
        .hearthDuoPose()
        // Profile › Appearance (HearthProfile.swift). BigTable shows Profile from its own sheet
        // rather than `.hearthProfile { }`, so it applies it here.
        .hearthAppearance()
        .animation(.smooth, value: model.phase)
        // The Hearth launch splash, held until the household has loaded (or 3 seconds).
        .hearthSplash(.bigtable, isReady: model.phase != .launching, isEnabled: !ScreenshotMode.isOn)
        // Community, AI and the like ask for Sign in with Apple when they're first used.
        .sheet(item: $model.signInReason) { reason in
            SignInSheet(reason: reason)
                .tint(accent)
                .environment(\.accent, accent)
        }
        // A new install: BigTable's onboarding, once, over everything.
        .fullScreenCover(isPresented: $showsOnboarding) {
            BigTableOnboarding { showsOnboarding = false }
                .environment(\.accent, accent)
        }
        .onChange(of: model.phase, initial: true) { _, _ in checkOnboarding() }
        .onChange(of: model.me?.profile?.tutorialComplete) { _, _ in checkOnboarding() }
        // The family's kitchen, or this person's iCloud, can say onboarding's done after it
        // opened: it closes (BigTableOnboarding.isNeeded).
        .onChange(of: KitchenStore.shared.isSetUp) { _, _ in recheckOpenOnboarding() }
        .onChange(of: HearthHouseholdStore.shared.isMember) { _, _ in recheckOpenOnboarding() }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification).receive(on: RunLoop.main)) { _ in
            recheckOpenOnboarding()
        }
        // The Hearth household and the kitchen in iCloud: invitations, sharing the kitchen with
        // the family, and the one-time move of what the server kept.
        .hearthHouseholdInvitations()
        // Someone set up before households (or who left one) gets the household step.
        .hearthHouseholdRequired(isActive: model.phase == .ready && !showsOnboarding && !ScreenshotMode.isOn, accent: accent)
        .task {
            guard !ScreenshotMode.isOn else { return }
            KitchenStore.shared.prepare()
            HearthHouseholdStore.shared.start(app: .bigtable)
            // The Apple Watch app: tonight's meal, cooking steps and the grocery list.
            WatchBridge.shared.start()
            // Onboarded before the family's kitchen and iCloud remembered it: say so now, so
            // the family's other devices skip onboarding and keep this device's shopping choice.
            if UserDefaults.standard.bool(forKey: BigTableOnboarding.doneKey) {
                HearthOnboarding.rememberInCloud(.bigtable)
                // After iCloud's copy of the kitchen is here, so older settings don't replace it.
                for _ in 0..<60 where !HearthHouseholdStore.shared.cloudLoaded {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard HearthHouseholdStore.shared.cloudLoaded else { return }
                KitchenStore.shared.markSetUp()
                if KitchenStore.shared.state.settings.warehouseSizes == nil,
                   let on = UserDefaults.standard.object(forKey: SettingsKey.warehouseSizes) as? Bool {
                    KitchenStore.shared.setWarehouseSizes(on)
                }
            }
        }
        // Not a .task(id:): these change the household themselves, which would cancel them.
        .onChange(of: KitchenCheck(phase: model.phase, userID: model.userID, household: HearthHouseholdStore.shared.snapshot, account: HearthHouseholdStore.shared.account), initial: true) { _, _ in
            guard !ScreenshotMode.isOn else { return }
            KitchenStore.shared.prepare()
            KitchenStore.shared.refreshLocation()
            model.householdChanged()
            Task {
                await KitchenMove.runIfNeeded(model: model)
                await KitchenSharing.update()
            }
        }
        // BigTable Plus or Hearth+ turned on (bought, restored, or the household's) or off: the
        // server's usage and tier set the AI limits, so fetch them again. RevenueCat's webhook
        // can land a moment after the purchase, so check once more shortly after.
        .onChange(of: purchases.isUnlocked) { _, _ in
            guard model.phase == .ready else { return }
            Task {
                await model.refreshUsage()
                try? await Task.sleep(for: .seconds(5))
                await model.refreshUsage()
            }
        }
        // Joined or left the organizer's plan (HearthKit keeps that in step with the household):
        // what this account can do, and its plan, come from the server.
        .onReceive(NotificationCenter.default.publisher(for: HearthHouseholdServer.membershipChanged)) { _ in
            guard model.phase == .ready else { return }
            Task { await model.reload() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Another Hearth app may have signed in, out, or as someone else meanwhile.
            if phase == .active {
                Task { await AuthClient.shared.followSharedSession() }
                HearthPhotoCache.shared.refreshIfChanged()
                // A new day means new meals on the watch.
                WatchBridge.shared.pushSoon()
                Task { await KitchenSharing.update() }
            } else {
                KitchenStore.shared.persistNow()
            }
            guard phase == .active, model.phase == .ready else { return }
            // HearthPurchases refreshes the plan itself when the app comes back.
            Task { await model.refreshUnreadCount() }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .profile: NavigationStack { ProfileView() }
        case .notifications:
            NavigationStack {
                if model.isSignedIn { NotificationsView() } else { SignInPrompt(reason: .notifications) }
            }
        case .newRecipe: RecipeEditorView(mode: .create)
        case .aiPlan: AIPlanView()
        case .recipe(let id, let version): NavigationStack { RecipeDetailView(recipeID: id, versionID: version) }
        case .publicProfile(let id): NavigationStack { PublicProfileView(profileID: id, showsCloseButton: true) }
        case .ask: AskView()
        }
    }
}

/// The first moment after launch, while the saved sign-in is read.
struct LaunchView: View {
    var body: some View {
        VStack(spacing: 18) {
            AppIconBadge(size: 84)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// Re-runs the kitchen's sharing and move when the app becomes ready, the household changes or
/// iCloud becomes available.
private struct KitchenCheck: Equatable {
    var phase: AppModel.Phase
    /// Signing in can start the one-time move of what the server kept.
    var userID: String?
    var household: HearthHouseholdSnapshot
    var account: HearthHouseholdStore.Account
}
