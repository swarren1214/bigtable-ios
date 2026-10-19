import CloudKit
import Foundation
import os

/// Shares the kitchen with the household (through `HearthAppSharing`: parents and adults, no
/// second invite) and shares the organizer's BigTable subscription: the owner's BigTable puts a
/// server join code in the household (encrypted); everyone else's redeems it.
@MainActor
enum KitchenSharing {
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "kitchen")
    private static var isRunning = false
    private static let redeemedCodeKey = "kitchen.redeemedJoinCode"

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
        if household.isMember {
            await redeemJoinCode()
        } else {
            await publishJoinCode()
        }
    }

    // MARK: Subscription

    private static func publishJoinCode() async {
        let household = HearthHouseholdStore.shared
        guard household.info?.joinCode == nil, AppModel.shared.phase == .ready, AppModel.shared.isOrganizer else { return }
        do {
            let code = try await BigTableAPI.shared.householdJoinCode()
            household.updateInfo(joinCode: code)
        } catch {
            log.error("Couldn't get a join code: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Everyone else

    private static func redeemJoinCode() async {
        let household = HearthHouseholdStore.shared
        guard let code = household.info?.joinCode, UserDefaults.standard.string(forKey: redeemedCodeKey) != code,
              AppModel.shared.phase == .ready else { return }
        do {
            _ = try await BigTableAPI.shared.joinHousehold(code: code)
            UserDefaults.standard.set(code, forKey: redeemedCodeKey)
            await AppModel.shared.reload()
        } catch let error as APIError where error.status == 409 {
            // Already in a household on the server (theirs, or this one): nothing to do.
            UserDefaults.standard.set(code, forKey: redeemedCodeKey)
        } catch {
            log.error("Couldn't join the family's plan: \(error.localizedDescription, privacy: .public)")
        }
    }
}
