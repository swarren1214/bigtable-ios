import Foundation
import Observation
import UserNotifications
import WatchKit
import WidgetKit

/// The cooking timer: one at a time, like a kitchen timer. It runs from an end date, so it keeps
/// time while the app is in the background; a notification taps the wrist when it's done, and
/// the complication counts down.
@MainActor
@Observable
final class CookTimer {
    static let shared = CookTimer()

    /// What it's for: "Simmer", "Step 5".
    private(set) var label = ""
    private(set) var recipe = ""
    private(set) var duration: TimeInterval = 0
    /// While running.
    private(set) var endsAt: Date?
    /// While paused: what was left.
    private(set) var pausedRemaining: TimeInterval?

    var isActive: Bool { endsAt != nil || pausedRemaining != nil }
    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at now: Date = .now) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endsAt else { return 0 }
        return max(0, endsAt.timeIntervalSince(now))
    }

    func progress(at now: Date = .now) -> Double {
        guard duration > 0 else { return 0 }
        return remaining(at: now) / duration
    }

    func start(seconds: Int, label: String, recipe: String) {
        self.label = label
        self.recipe = recipe
        duration = TimeInterval(seconds)
        pausedRemaining = nil
        endsAt = .now.addingTimeInterval(duration)
        WKInterfaceDevice.current().play(.start)
        scheduleAlert()
    }

    func addMinute() {
        if let pausedRemaining {
            self.pausedRemaining = pausedRemaining + 60
        } else if let endsAt {
            self.endsAt = max(endsAt, .now).addingTimeInterval(60)
        }
        duration += 60
        scheduleAlert()
    }

    func togglePause() {
        if let pausedRemaining {
            endsAt = .now.addingTimeInterval(pausedRemaining)
            self.pausedRemaining = nil
        } else if endsAt != nil {
            pausedRemaining = remaining()
            endsAt = nil
        }
        scheduleAlert()
    }

    func stop() {
        endsAt = nil
        pausedRemaining = nil
        scheduleAlert()
    }

    /// Called by the timer screen when it reaches zero while it's on screen.
    func finished() {
        guard endsAt != nil else { return }
        WKInterfaceDevice.current().play(.notification)
        endsAt = nil
        scheduleAlert()
    }

    private static let alertID = "bigtable.cook-timer"

    /// The notification for when it's done (replaced on every change), and the complication's copy.
    private func scheduleAlert() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.alertID])
        let defaults = WatchShared.defaults
        if let endsAt {
            defaults.set(endsAt, forKey: WatchShared.timerEndKey)
            defaults.set(label, forKey: WatchShared.timerLabelKey)
        } else {
            defaults.removeObject(forKey: WatchShared.timerEndKey)
            defaults.removeObject(forKey: WatchShared.timerLabelKey)
        }
        WidgetCenter.shared.reloadAllTimelines()

        guard let endsAt else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(label) is done"
        if !recipe.isEmpty { content.body = recipe }
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, endsAt.timeIntervalSinceNow), repeats: false)
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(UNNotificationRequest(identifier: Self.alertID, content: content, trigger: trigger))
        }
    }
}
