import Foundation
import Observation
import OSLog
import RevenueCat

/// BigTable Pro through RevenueCat, as in the Expo app: the same entitlement, offerings and
/// App Store products, with the Supabase user id as the RevenueCat app user id. RevenueCat's
/// webhook keeps the API's `subscriptions` table current, which is what the server's AI limits
/// read, so purchases here unlock the server features right away.
@MainActor
@Observable
final class Subscriptions {
    static let shared = Subscriptions()

    nonisolated struct Plan: Identifiable, Hashable, Sendable {
        var id: String
        var title: String
        var price: String
        /// "$4.67 / month" for the annual plan.
        var perMonth: String?
        var isAnnual: Bool
        var trial: String?
    }

    private(set) var isPro = false
    private(set) var plans: [Plan] = []
    private(set) var isLoading = false
    private(set) var expirationDate: Date?
    private(set) var willRenew = false
    private(set) var managementURL: URL?
    var lastError: String?

    private var packages: [String: Package] = [:]
    private var configured = false
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "subscriptions")

    private func configureIfNeeded(userID: String?) {
        guard !configured else { return }
        configured = true
        #if DEBUG
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(withAPIKey: AppConfig.revenueCatAPIKey, appUserID: userID)
    }

    func signedIn(userID: String) async {
        // Screenshot mode (Debug): Pro, without RevenueCat or the App Store.
        if ScreenshotMode.isOn {
            isPro = true
            willRenew = true
            expirationDate = Calendar.current.date(byAdding: .month, value: 10, to: .now)
            return
        }
        configureIfNeeded(userID: userID)
        do {
            if Purchases.shared.appUserID != userID {
                let (info, _) = try await Purchases.shared.logIn(userID)
                apply(info)
            } else {
                apply(try await Purchases.shared.customerInfo())
            }
        } catch {
            Self.log.error("RevenueCat sign-in failed: \(error.localizedDescription, privacy: .public)")
        }
        await loadPlans()
    }

    func signedOut() async {
        guard configured else { return }
        isPro = false
        _ = try? await Purchases.shared.logOut()
    }

    func refresh() async {
        guard configured else { return }
        if let info = try? await Purchases.shared.customerInfo() { apply(info) }
    }

    func loadPlans() async {
        guard configured else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let offerings = try await Purchases.shared.offerings()
            let available = offerings.current?.availablePackages ?? []
            packages = Dictionary(available.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            plans = available
                .filter { [AppConfig.proMonthlyProductID, AppConfig.proAnnualProductID].contains($0.storeProduct.productIdentifier) || $0.packageType == .monthly || $0.packageType == .annual }
                .map { package in
                    let product = package.storeProduct
                    let annual = package.packageType == .annual || product.productIdentifier == AppConfig.proAnnualProductID
                    return Plan(
                        id: package.identifier,
                        title: annual ? "Annual" : "Monthly",
                        price: product.localizedPriceString,
                        perMonth: annual ? product.localizedPricePerMonth.map { "\($0) / month" } : nil,
                        isAnnual: annual,
                        trial: product.introductoryDiscount.map { "\($0.subscriptionPeriod.value) \($0.subscriptionPeriod.unit) free" }
                    )
                }
                .sorted { $0.isAnnual && !$1.isAnnual }
            if plans.isEmpty {
                lastError = "Subscriptions aren't available right now. Try again later."
            }
        } catch {
            lastError = "Subscriptions aren't available right now. Try again later."
            Self.log.error("Offerings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Buys a plan. Returns true when Pro is active afterwards.
    @discardableResult
    func purchase(_ plan: Plan) async -> Bool {
        guard let package = packages[plan.id] else { return false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if !result.userCancelled { apply(result.customerInfo) }
            await AppModel.shared.refreshUsage()
            return isPro
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func restore() async {
        do {
            apply(try await Purchases.shared.restorePurchases())
            await AppModel.shared.refreshUsage()
            if !isPro { lastError = "No active BigTable Pro subscription was found for this Apple Account." }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(_ info: CustomerInfo) {
        let entitlement = info.entitlements[AppConfig.proEntitlement]
        isPro = entitlement?.isActive == true
        expirationDate = entitlement?.expirationDate
        willRenew = entitlement?.willRenew == true
        managementURL = info.managementURL
    }
}
