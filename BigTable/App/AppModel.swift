import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit
import UserNotifications

/// Who's signed in and their household, shared by every screen: the session from
/// `AuthClient`, `/v1/bigtable/me` (the household, its people and restrictions, and the membership),
/// this person's permissions, and AI usage.
///
/// The organizer owns the household; members who joined see the organizer's plan and grocery
/// list and can do what the organizer allowed (`permissions`).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable {
        /// Reading the saved session.
        case launching
        case signedOut
        /// Signed in; `/v1/bigtable/me` is loading.
        case loading
        /// Signed in with no household set up yet.
        case needsHousehold
        case ready
    }

    private(set) var phase: Phase = .launching
    private(set) var session: AuthSession?
    private(set) var me: MeResponse?
    private(set) var permissions: HouseholdMemberPermissions = .organizer
    private(set) var usage: UsageCheckResponse?
    /// The last thing that went wrong loading the household, shown with Try Again.
    private(set) var loadError: String?
    /// A password-reset link was opened: ask for the new password.
    var needsNewPassword = false
    /// Unread notifications, for the bell's badge.
    private(set) var unreadCount = 0

    let api = BigTableAPI.shared
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "app")

    // MARK: Who and what

    var userID: String? { session?.user.id }
    var membership: MembershipInfo? { me?.membership }
    var isOrganizer: Bool { (membership?.role ?? .organizer) == .organizer }
    var members: [HouseholdMember] { me?.householdMembers ?? [] }
    var householdName: String {
        if !isOrganizer, let name = membership?.organizerHouseholdName, !name.isEmpty { return name }
        return me?.profile?.householdName ?? ""
    }

    var canManagePlan: Bool { isOrganizer || permissions.canManageMealPlan }
    var canUseAIPlan: Bool { isOrganizer || permissions.canUseAiMealPlan }
    var canUseAIGrocery: Bool { isOrganizer || permissions.canUseAiGrocery }
    var canEditMembers: Bool { isOrganizer || permissions.canEditMembers }

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
            HearthPublisher.clear()
            usage = nil
            permissions = .organizer
            phase = .signedOut
            Task { await HearthPurchases.shared.followSignIn() }
            return
        }
        // A token refresh for the same person changes nothing on screen.
        guard previous != new.user.id || phase == .launching || phase == .signedOut else { return }
        phase = .loading
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

    /// Loads `/v1/bigtable/me`, then permissions and usage.
    func reload() async {
        do {
            let me = try await api.me()
            self.me = me
            HearthPublisher.publishFamily(me, householdName: householdName.isEmpty ? nil : householdName, userID: userID)
            loadError = nil
            if let membership = me.membership, membership.role == .member, let id = userID {
                permissions = (try? await api.memberPermissions(id)) ?? .none
            } else {
                permissions = .organizer
            }
            phase = isSetUp(me) ? .ready : .needsHousehold
            await refreshUsage()
            if phase == .ready { await requestPushIfNeeded() }
        } catch let error as APIError where error.kind == .signedOut {
            await AuthClient.shared.clear()
        } catch {
            Self.log.error("Couldn't load the household: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
            if phase == .loading { phase = me == nil ? .loading : .ready }
        }
    }

    /// Ready to cook: set up before (on the server, the old way), in someone's household, with
    /// a Hearth household, or started as just this person.
    private func isSetUp(_ me: MeResponse) -> Bool {
        me.isOnboarded || me.membership?.role == .member || HearthHouseholdStore.shared.exists
            || userID.map { UserDefaults.standard.bool(forKey: "bigtable.setUp.\($0)") } == true
    }

    /// The first run is done (a household was set up or joined, or "Just me for now").
    func markSetUp() {
        if let userID { UserDefaults.standard.set(true, forKey: "bigtable.setUp.\(userID)") }
        if phase == .needsHousehold { phase = .ready }
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
        usage = try? await api.usage()
    }

    /// After an AI call: the response carries the new usage.
    func updateUsage(_ new: UsageCheckResponse) {
        usage = new
    }

    /// Saves the household, then reloads `/v1/bigtable/me`: the PUT's reply leaves out the membership
    /// (and, for someone who joined, is just `{ ok: true }`).
    func saveHousehold(_ payload: SaveHouseholdPayload) async throws {
        _ = try await api.saveHousehold(payload)
        await reload()
    }

    func markTutorialComplete() {
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

    /// bigtable://auth links from the confirmation and password-reset emails.
    func handleAuthRedirect(_ url: URL) async {
        do {
            if try await AuthClient.shared.handleRedirect(url) == "recovery" {
                needsNewPassword = true
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}
