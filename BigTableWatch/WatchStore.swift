import Foundation
import Observation
import WatchConnectivity
import WidgetKit
import os

/// The watch's copy of what BigTable on the iPhone sent (WatchSnapshot), kept on the watch so the
/// app and its complications open instantly and work while the phone is away. Check-offs show at
/// once and are queued to the phone.
@MainActor
@Observable
final class WatchStore: NSObject {
    static let shared = WatchStore()

    private(set) var snapshot: WatchSnapshot = WatchShared.loadSnapshot() ?? .empty
    /// Whether the phone has ever sent anything.
    var hasData: Bool { snapshot.generatedAt != .distantPast }
    var isReachable = false

    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.bigtable.watchkitapp", category: "watch")
    @ObservationIgnored private var started = false

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Asks the phone for a fresh snapshot (it sends one when anything changes, too).
    func refresh() {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([WatchKeys.kind: WatchKeys.refresh], replyHandler: { _ in }, errorHandler: nil)
    }

    // MARK: - Grocery

    func toggle(_ item: WatchGroceryItem) {
        guard var grocery = snapshot.grocery else { return }
        let checked = !grocery.isChecked(item)
        grocery.checks[item.id] = checked
        snapshot.grocery = grocery
        save()
        // Queued: delivered when the phone is next around, in order.
        WCSession.default.transferUserInfo([
            WatchKeys.kind: WatchKeys.check,
            WatchKeys.itemID: item.id,
            WatchKeys.listID: grocery.id,
            WatchKeys.checked: checked,
        ])
    }

    // MARK: - Tell the Pantry

    enum PantryError: LocalizedError {
        case phoneAway
        case failed

        var errorDescription: String? {
            switch self {
            case .phoneAway: "Your iPhone needs to be nearby to update the pantry."
            case .failed: "The pantry couldn't be updated. Try again."
            }
        }
    }

    /// Sends what was said to the phone, which updates the pantry and says what changed.
    func tellPantry(_ text: String) async throws -> [WatchPantryLine] {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { throw PantryError.phoneAway }
        let message: [String: Any] = [WatchKeys.kind: WatchKeys.pantry, WatchKeys.text: text]
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(message, replyHandler: { reply in
                nonisolated(unsafe) let reply = reply
                continuation.resume(returning: reply)
            }, errorHandler: { error in
                continuation.resume(throwing: error)
            })
        }
        guard let data = reply[WatchKeys.lines] as? Data,
              let lines = try? JSONDecoder().decode([WatchPantryLine].self, from: data) else { throw PantryError.failed }
        return lines
    }

    // MARK: - Saving

    private func receive(_ data: Data) {
        guard let incoming = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else {
            log.error("Couldn't read the snapshot from the phone")
            return
        }
        snapshot = incoming
        save()
    }

    private func save() {
        WatchShared.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext[WatchKeys.snapshot] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            if let data { self.receive(data) }
            self.isReachable = reachable
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchKeys.snapshot] as? Data else { return }
        Task { @MainActor in self.receive(data) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
}
