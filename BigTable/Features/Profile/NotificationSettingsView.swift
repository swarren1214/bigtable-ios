import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Profile › Notifications: push notifications on this device, and which Community activity
/// to hear about.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @AppStorage(ProfilePush.disabledKey) private var pushDisabled = false
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var pushOn = false
    @State private var isUpdatingPush = false
    @State private var showDeniedAlert = false
    @State private var prefs: [String: Bool] = [:]
    @State private var prefsLoaded = false
    @State private var prefsError: String?
    @State private var savingPrefs: Set<String> = []
    @State private var errorMessage: String?

    /// The kinds the API lets people switch off (the household ones always arrive).
    private let prefTypes: [NotificationType] = [.recipePublished, .recipeUpdated, .recipeLiked, .recipeSaved, .newFollower]

    private var pushBinding: Binding<Bool> {
        Binding(get: { pushOn }, set: { on in Task { await setPush(on) } })
    }

    var body: some View {
        BigTableScreen(title: "Notifications") {
            if AppConfig.pushEnabled {
                ProfileCard {
                    ProfileToggleRow(
                        symbol: "bell.badge",
                        color: Brand.allergy,
                        title: "Push notifications",
                        detail: pushDetail,
                        isOn: pushBinding,
                        isDisabled: isUpdatingPush
                    )
                }
            }

            if AppConfig.socialEnabled {
                SectionTitle("Community")
                if prefsLoaded {
                    ProfileCard {
                        ForEach(Array(prefTypes.enumerated()), id: \.element.rawValue) { index, type in
                            if index > 0 { ProfileDivider() }
                            ProfileToggleRow(
                                symbol: symbol(for: type),
                                color: PersonColor.forIndex(index).color,
                                title: type.settingLabel,
                                isOn: prefBinding(type),
                                isDisabled: savingPrefs.contains(type.rawValue)
                            )
                        }
                    }
                    Text("Household invitations and changes always come through.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                } else if let prefsError {
                    RetryCard(message: prefsError) { Task { await loadPrefs() } }
                } else {
                    LoadingCard()
                }
            }
        }
        .task {
            await refreshPush()
            await loadPrefs()
        }
        .alert("Notifications are off for BigTable", isPresented: $showDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Turn on notifications for BigTable in Settings, then switch this on again.")
        }
        .errorAlert($errorMessage)
    }

    private var pushDetail: String {
        switch authorization {
        case .denied: "Turned off in Settings."
        default: "Invitations, new recipes from people you follow, and likes."
        }
    }

    private func symbol(for type: NotificationType) -> String {
        switch type {
        case .recipePublished: "book.closed"
        case .recipeUpdated: "arrow.triangle.2.circlepath"
        case .recipeLiked: "heart"
        case .recipeSaved: "bookmark"
        case .newFollower: "person.badge.plus"
        default: "bell"
        }
    }

    // MARK: Push

    private func refreshPush() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
        let allowedStatuses: [UNAuthorizationStatus] = [.authorized, .provisional, .ephemeral]
        let allowed = allowedStatuses.contains(settings.authorizationStatus)
        pushOn = allowed && !pushDisabled
    }

    private func setPush(_ on: Bool) async {
        isUpdatingPush = true
        defer { isUpdatingPush = false }
        if on {
            pushDisabled = false
            if authorization == .denied {
                pushOn = false
                showDeniedAlert = true
                return
            }
            await model.requestPushIfNeeded()
            await refreshPush()
            if authorization == .denied { showDeniedAlert = true }
        } else {
            pushDisabled = true
            pushOn = false
            UIApplication.shared.unregisterForRemoteNotifications()
            await ProfilePush.disableServerTokens()
        }
    }

    // MARK: Preferences

    private func prefBinding(_ type: NotificationType) -> Binding<Bool> {
        Binding(
            get: { prefs[type.rawValue] != false },
            set: { on in Task { await setPref(type, on) } }
        )
    }

    private func loadPrefs() async {
        guard AppConfig.socialEnabled else { return }
        prefsError = nil
        do {
            prefs = try await model.api.notificationPrefs()
            prefsLoaded = true
        } catch {
            prefsError = FriendlyError.message(error)
        }
    }

    private func setPref(_ type: NotificationType, _ on: Bool) async {
        let previous = prefs[type.rawValue]
        prefs[type.rawValue] = on
        savingPrefs.insert(type.rawValue)
        defer { savingPrefs.remove(type.rawValue) }
        do {
            prefs = try await model.api.setNotificationPrefs([type.rawValue: on])
        } catch {
            prefs[type.rawValue] = previous
            errorMessage = FriendlyError.message(error)
        }
    }
}
