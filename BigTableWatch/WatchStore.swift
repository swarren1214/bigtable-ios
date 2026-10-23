import Foundation
import Observation
import WatchConnectivity
import WatchKit
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

    /// What was last said to Tell the Pantry, and how it's going.
    struct PantryRequest: Equatable {
        enum Status: Equatable {
            /// On its way to the phone.
            case sending
            /// The phone has it and is putting it away.
            case working
            /// Sent, but the result isn't back yet (the phone is away or slow). It still shows
            /// up here when it comes.
            case waiting
            case done([WatchPantryLine])
            case failed(String)
        }

        var id: String
        var text: String
        var status: Status
    }

    private(set) var pantryRequest: PantryRequest?

    /// Sends what was said to the phone, which updates the pantry and sends back what changed.
    /// The phone answers "received" at once and the result separately, so the result arrives
    /// even if this app was in the background meanwhile; and the wait never runs forever.
    func tellPantry(_ text: String) {
        let id = UUID().uuidString
        pantryRequest = PantryRequest(id: id, text: text, status: .sending)
        let session = WCSession.default
        guard session.activationState == .activated else {
            pantryRequest?.status = .failed("Open BigTable on your iPhone, then try again.")
            return
        }
        let message: [String: Any] = [WatchKeys.kind: WatchKeys.pantry, WatchKeys.text: text, WatchKeys.requestID: id]
        if session.isReachable {
            session.sendMessage(message, replyHandler: { _ in
                Task { @MainActor in WatchStore.shared.update(id, to: .working, from: [.sending]) }
            }, errorHandler: { _ in
                // Not sure it got there: queue it too (the phone does each request only once).
                WCSession.default.transferUserInfo(message)
                Task { @MainActor in WatchStore.shared.update(id, to: .waiting, from: [.sending, .working]) }
            })
        } else {
            // Queued: the phone puts it away when it's next around.
            session.transferUserInfo(message)
            pantryRequest?.status = .waiting
        }
        // Never spin for good.
        Task {
            try? await Task.sleep(for: .seconds(25))
            update(id, to: .waiting, from: [.sending, .working])
        }
    }

    func clearPantryRequest() {
        pantryRequest = nil
    }

    /// Moves a request along, if it's still the current one (and, given `from`, only from those).
    private func update(_ id: String, to status: PantryRequest.Status, from: [PantryRequest.Status]? = nil) {
        guard let current = pantryRequest, current.id == id else { return }
        if let from, !from.contains(current.status) { return }
        pantryRequest?.status = status
    }

    /// What the phone changed, for the request it answers.
    private func receivePantryResult(_ info: [String: Any]) {
        guard let id = info[WatchKeys.requestID] as? String,
              let data = info[WatchKeys.lines] as? Data,
              let lines = try? JSONDecoder().decode([WatchPantryLine].self, from: data) else { return }
        guard pantryRequest?.id == id else { return }
        update(id, to: .done(lines))
        WKInterfaceDevice.current().play(.success)
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

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message[WatchKeys.kind] as? String == WatchKeys.pantryResult else { return }
        nonisolated(unsafe) let message = message
        Task { @MainActor in self.receivePantryResult(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo[WatchKeys.kind] as? String == WatchKeys.pantryResult else { return }
        nonisolated(unsafe) let userInfo = userInfo
        Task { @MainActor in self.receivePantryResult(userInfo) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
}
