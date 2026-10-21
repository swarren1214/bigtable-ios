import AuthenticationServices
import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit
import UserNotifications

/// Who's signed in, shared by every screen: the session from `AuthClient` (optional: the kitchen,
/// recipes, plan and grocery list work signed out), `/v1/bigtable/me` when signed in (the
/// community profile), and AI usage.
///
/// The household is HearthKit's (`HearthHouseholdStore`, in iCloud), the same in every Hearth
/// app. Its organizer owns the kitchen; everyone else's role decides what they can do with the
/// organizer's plan: parents everything, adults the meal plan and AI, kids neither. The server
/// follows the same roles (`HearthHouseholdServer`). Community, AI and sharing the organizer's
/// plan need Sign in with Apple.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable {
        /// Reading the saved session.
        case launching
        /// No household set up yet (signed in or not).
        case needsHousehold
        case ready
    }

    private(set) var phase: Phase = .launching
    private(set) var session: AuthSession?
    private(set) var me: MeResponse?
    private(set) var usage: UsageCheckResponse?
    /// The last thing that went wrong loading the household, shown with Try Again.
    private(set) var loadError: String?
    /// Why Sign in with Apple is being asked for, while the sheet is up (`requireSignIn`).
    var signInReason: SignInReason?
    /// Unread notifications, for the bell's badge.
    private(set) var unreadCount = 0

    let api = BigTableAPI.shared
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "app")

    // MARK: Who and what

    var userID: String? { session?.user.id }
    var isSignedIn: Bool { session != nil }
    var membership: MembershipInfo? { me?.membership }
    /// The household's organizer (or someone in their own household, or with none yet): owns the
    /// kitchen and its plan.
    var isOrganizer: Bool { !HearthHouseholdStore.shared.isMember }
    /// Older server-side household people, for screens that haven't moved to HearthKit's.
    var members: [HouseholdMember] { [] }
    var householdName: String { HearthHouseholdStore.shared.info?.name ?? "" }

    /// Their role in the household, when they're in someone else's.
    private var memberRole: HearthRole? {
        let household = HearthHouseholdStore.shared
        guard household.isMember else { return nil }
        return household.me?.role ?? .adult
    }

    var canManagePlan: Bool { memberRole != .kid }
    var canUseAIPlan: Bool { memberRole != .kid }
    var canUseAIGrocery: Bool { memberRole != .kid }
    var canEditMembers: Bool { HearthHouseholdStore.shared.canEditEveryone }

    /// BigTable Plus or Hearth+: bought on this Apple Account, family-shared, or the household
    /// organizer's (HearthKit's `HearthPurchases`, which reads the household's plan from
    /// `/v1/me/entitlements`), or the server's tier says Pro. The server's usage and tier still
    /// set the AI limits.
    var hasPro: Bool { HearthPurchases.shared.isUnlocked || usage?.isPro == true }

    // MARK: Starting up

    func start() async {
        configurePurchases()
        await AuthClient.shared.observe { session in
            Task { @MainActor in AppModel.shared.sessionChanged(session) }
        }
    }

    private func sessionChanged(_ new: AuthSession?) {
        let previous = session?.user.id
        session = new
        guard let new else {
            me = nil
            usage = nil
            unreadCount = 0
            loadError = nil
            updatePhase()
            Task { await HearthPurchases.shared.followSignIn() }
            return
        }
        // A token refresh for the same person changes nothing on screen.
        guard previous != new.user.id || phase == .launching else { return }
        // The kitchen doesn't wait for the server: it's in iCloud.
        if previous != nil { me = nil; usage = nil }
        updatePhase()
        signInReason = nil
        Task {
            await HearthPurchases.shared.followSignIn()
            await reload()
        }
    }

    /// BigTable Plus and Hearth+ through HearthKit: the app's only RevenueCat setup. The
    /// RevenueCat app user id is the shared Hearth sign-in's user id (the Supabase user id, as
    /// before), so current BigTable Plus subscribers carry over.
    private func configurePurchases() {
        let purchases = HearthPurchases.shared
        // Screenshot mode (Debug): everything unlocked, no RevenueCat or App Store.
        if ScreenshotMode.isOn { purchases.previewUnlocked = true }
        guard AppConfig.revenueCatAPIKey != "REVENUECAT_PUBLIC_KEY" else { return }
        // Loading the saved session first shares it as the Hearth sign-in RevenueCat follows.
        _ = AuthClient.shared
        purchases.configure(
            app: .bigtable,
            apiKey: AppConfig.revenueCatAPIKey,
            apiBaseURL: AppConfig.apiBaseURL,
            accessToken: { try? await AuthClient.shared.accessToken() },
            signInButton: {
                AnyView(AccountAppleSignInButton(label: .signIn) { message in
                    AppModel.log.error("Sign in with Apple from the paywall failed: \(message, privacy: .public)")
                })
            }
        )
    }

    /// Signed in: loads `/v1/bigtable/me` (the community profile) and AI usage.
    func reload() async {
        guard isSignedIn else {
            updatePhase()
            return
        }
        do {
            let me = try await api.me()
            self.me = me
            loadError = nil
            if me.isOnboarded { markSetUp() }
            updatePhase()
            await refreshUsage()
            if phase == .ready { await requestPushIfNeeded() }
        } catch let error as APIError where error.kind == .signedOut {
            await AuthClient.shared.clear()
        } catch {
            Self.log.error("Couldn't load the account: \(error.localizedDescription, privacy: .public)")
            loadError = FriendlyError.message(error, fallback: "BigTable couldn't load your account. Check your connection and try again.")
        }
    }

    /// Ready to cook once there's a household (HearthKit's, from any Hearth app), or after the
    /// first run on this device (set up before, or "Just me for now").
    private func updatePhase() {
        let setUp = HearthHouseholdStore.shared.exists || HearthHouseholdStore.shared.isMember
            || UserDefaults.standard.bool(forKey: Self.setUpKey)
            || userID.map { UserDefaults.standard.bool(forKey: "bigtable.setUp.\($0)") } == true
        // A fresh install: give iCloud a moment to bring the family's household before offering
        // to set one up (the launch splash covers it).
        if !setUp, phase == .launching, !HearthHouseholdStore.shared.hasLoaded, !waitedForHousehold {
            if householdWait == nil {
                householdWait = Task {
                    try? await Task.sleep(for: .seconds(4))
                    waitedForHousehold = true
                    updatePhase()
                }
            }
            return
        }
        phase = setUp ? .ready : .needsHousehold
    }

    @ObservationIgnored private var householdWait: Task<Void, Never>?
    @ObservationIgnored private var waitedForHousehold = false

    private static let setUpKey = "bigtable.setUp"

    /// The household appeared or changed (here or in another Hearth app).
    func householdChanged() {
        if phase != .ready { updatePhase() }
    }

    /// The first run is done (a household was set up or joined, or "Just me for now").
    func markSetUp() {
        UserDefaults.standard.set(true, forKey: Self.setUpKey)
        if phase == .needsHousehold { phase = .ready }
    }

    // MARK: Sign in with Apple

    /// Signed in: true. Signed out: asks them to sign in (the sheet says why) and returns false.
    /// For Community, AI, and anything else that needs the Hearth API.
    @discardableResult
    func requireSignIn(_ reason: SignInReason) -> Bool {
        if isSignedIn { return true }
        signInReason = reason
        return false
    }

    func refreshUnreadCount() async {
        guard AppConfig.socialEnabled, session != nil else { return }
        if let count = try? await api.unreadNotificationCount() {
            unreadCount = count
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        }
    }

    func setUnreadCount(_ count: Int) {
        unreadCount = count
    }

    /// Asks for notification permission once (after the household is set up) and registers.
    func requestPushIfNeeded() async {
        // Screenshot mode (Debug) never asks.
        guard AppConfig.pushEnabled, !ScreenshotMode.isOn, !UserDefaults.standard.bool(forKey: SettingsKey.pushDisabled) else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true else { return }
        case .denied:
            return
        default:
            break
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func refreshUsage() async {
        guard isSignedIn else { return }
        usage = try? await api.usage()
    }

    /// After an AI call: the response carries the new usage.
    func updateUsage(_ new: UsageCheckResponse) {
        usage = new
    }

    func markTutorialComplete() {
        guard isSignedIn else { return }
        Task { try? await api.markTutorialComplete() }
    }

    func signOut() async {
        await AuthClient.shared.signOut()
    }

    func deleteAccount() async throws {
        try await api.deleteAccount()
        // The account is gone, so the other Hearth apps signed in with it are signed out too.
        await AuthClient.shared.clear(everywhere: true)
    }
}

/// Why BigTable is asking someone to sign in with Apple: what it's for, in the sheet.
enum SignInReason: String, Identifiable {
    case community
    case aiPlan
    case aiGrocery
    case recipeAI
    case publishing
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .community: "Join the Community"
        case .aiPlan: "Plan with AI"
        case .aiGrocery: "Make Lists with AI"
        case .recipeAI: "Recipes with AI"
        case .publishing: "Share Your Recipes"
        case .notifications: "Notifications"
        }
    }

    var message: String {
        switch self {
        case .community: "Sign in with Apple to follow cooks, like and save their recipes, and share your own."
        case .aiPlan: "Sign in with Apple to plan your week with AI. It's the same Hearth account in every Hearth app."
        case .aiGrocery: "Sign in with Apple to turn your plan into a grocery list with AI."
        case .recipeAI: "Sign in with Apple to scan, import and refine recipes with AI."
        case .publishing: "Sign in with Apple to publish recipes to the Community."
        case .notifications: "Sign in with Apple to get likes, follows and household news."
        }
    }

    var systemImage: String {
        switch self {
        case .community: "person.2"
        case .aiPlan, .aiGrocery, .recipeAI: "sparkles"
        case .publishing: "square.and.arrow.up"
        case .notifications: "bell"
        }
    }
}
