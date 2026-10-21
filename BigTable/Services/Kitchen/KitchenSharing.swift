import CloudKit
import Foundation

/// Shares the kitchen with the household (through `HearthAppSharing`: parents and adults, no
/// second invite). The organizer's plan reaches the family through HearthKit
/// (`HearthHouseholdServer`), from whichever Hearth app runs first.
@MainActor
enum KitchenSharing {
    private static var isRunning = false

    /// Call on launch, coming to the foreground and when the household changes. Safe to call
    /// often: it only changes what's out of date.
    static func update() async {
        let household = HearthHouseholdStore.shared
        guard !isRunning, !ScreenshotMode.isOn, household.exists else { return }
        isRunning = true
        defer { isRunning = false }
        var joinedOwner: String?
        await HearthAppSharing.update(app: .bigtable, zoneName: KitchenStore.kitchenZoneName, title: "Kitchen", audience: .adults) { owner in
            joinedOwner = owner
        }
        if let joinedOwner, !KitchenStore.shared.hasJoinedFamilyKitchen {
            KitchenStore.shared.markJoined(joinedOwner)
            await KitchenStore.shared.syncNow()
        }
    }
}
