// HearthPurchases.swift — what someone has paid for, in every Hearth app: the app's own plan
// (BigTable Plus, Suffice Plus, …) or Hearth+, which unlocks all five. Bought through RevenueCat
// (one project for all five apps), shared with the family through Apple Family Sharing and,
// for households bigger than that, through the Hearth API.
//
// Canonical copy: ~/Developer/hearthkit/HearthPurchases.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh. Needs HearthShared.swift (for
// `HearthApp`, `HearthAccounts`) and the RevenueCat package. How it all fits: MONETIZATION.md.
//
// Using it
// - At launch: `HearthPurchases.shared.configure(app: .suffice, apiKey: AppConfig.revenueCatAPIKey,
//   apiBaseURL: AppConfig.apiBaseURL) { await api.accessTokenIfSignedIn() }`. The closure returns
//   the Hearth API access token when someone is signed in (nil otherwise); it's how members of a
//   household get the organizer's plan.
// - Read `isUnlocked` (this app's paid tier) and `hasHearthPlus` (the cross-app features). Both
//   are observable.
// - Show the paywall with `.hearthPaywall(isPresented:feature:)`; put `HearthLockedCard` where a
//   paid feature would be (HearthPaywall.swift).
// - Signing in and out needs nothing: this follows the shared Hearth sign-in
//   (`HearthAccounts.session()`), so a purchase made signed out moves to the account on sign-in.

import Foundation
import Observation
import OSLog
import RevenueCat
import SwiftUI

// MARK: - Plans and entitlements

nonisolated enum HearthEntitlement {
    /// Every app's paid tier, plus the apps working together.
    static let hearthPlus = "hearth_plus"

    /// BigTable's plan before it was renamed BigTable Plus. The products behind it count as
    /// BigTable Plus too; the App Store's BigTable 1.x still reads this key.
    static let legacyBigTablePro = "BigTable Pro"

    /// The app's own plan.
    static func plan(for app: HearthApp) -> String {
        switch app {
        case .bigtable: "bigtable_plus"
        case .suffice: "suffice_plus"
        case .sated: "sated_plus"
        case .caloma: "caloma_plus"
        case .hearken: "hearken_plus"
        }
    }
}

nonisolated extension HearthApp {
    /// "BigTable Plus", "Suffice Plus".
    var planName: String { "\(displayName) Plus" }
}

/// One way to pay: Hearth+ or the app's plan, monthly, yearly or once.
nonisolated struct HearthPlan: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Sendable { case app, hearthPlus }
    nonisolated enum Term: String, Sendable { case monthly, annual, lifetime }

    /// The RevenueCat package identifier.
    var id: String
    var kind: Kind
    var term: Term
    /// "$99.99".
    var price: String
    var priceValue: Decimal
    /// "$8.33" for yearly plans.
    var perMonth: String?
    /// Days of free trial the product offers, when it offers one.
    var trialDays: Int?
    /// False once this Apple Account has had the trial.
    var eligibleForTrial: Bool

    var offersTrial: Bool { trialDays != nil && eligibleForTrial }
}

/// What someone has right now.
nonisolated struct HearthMembership: Equatable, Sendable {
    nonisolated enum Source: Sendable, Equatable {
        /// Bought on this Apple Account.
        case own
        /// Through Apple Family Sharing.
        case familySharing
        /// The household organizer's plan, through the Hearth API.
        case household
    }

    var kind: HearthPlan.Kind
    var term: HearthPlan.Term?
    var source: Source
    /// When it renews or ends; nil for lifetime.
    var expiresAt: Date?
    var willRenew: Bool
    var isTrial: Bool

    /// "Hearth+ · Yearly".
    func title(for app: HearthApp) -> String {
        let name = kind == .hearthPlus ? "Hearth+" : app.planName
        guard let term else { return name }
        switch term {
        case .monthly: return "\(name) · Monthly"
        case .annual: return "\(name) · Yearly"
        case .lifetime: return "\(name) · Lifetime"
        }
    }
}

// MARK: - The store

@MainActor
@Observable
final class HearthPurchases {
    static let shared = HearthPurchases()

    enum PlansState: Equatable { case idle, loading, loaded, unavailable }

    enum PurchaseOutcome: Equatable {
        case purchased
        case cancelled
        /// Ask to Buy, or a payment the bank still has to approve.
        case pending
        case failed(String)
    }

    enum RestoreOutcome: Equatable {
        case restored
        case nothing
        case failed(String)
    }

    private(set) var app: HearthApp = .caloma
    private(set) var isConfigured = false

    /// This app's paid tier is on: its own plan or Hearth+, bought, family-shared or the household's.
    var isUnlocked: Bool { previewUnlocked || membership != nil }
    /// Hearth+ is on, which also turns on the apps working together.
    var hasHearthPlus: Bool { previewUnlocked || membership?.kind == .hearthPlus }
    private(set) var membership: HearthMembership?
    /// The renewal failed and Apple is retrying; the plan stays on until this date.
    private(set) var billingIssueUntil: Date?
    /// The person bought Hearth+ signed out, so only this app knows about it yet.
    var needsAccountLink: Bool {
        membership?.kind == .hearthPlus && membership?.source != .household && !isSignedIn
    }
    private(set) var isSignedIn = false

    private(set) var appPlans: [HearthPlan] = []
    private(set) var hearthPlans: [HearthPlan] = []
    private(set) var tips: [HearthPlan] = []
    private(set) var plansState: PlansState = .idle
    private(set) var managementURL: URL?

    /// Screenshots and previews: everything unlocked, no store.
    var previewUnlocked = false

    @ObservationIgnored private var packages: [String: Package] = [:]
    @ObservationIgnored private var apiBaseURL: URL?
    @ObservationIgnored private var accessToken: (@MainActor () async -> String?)?
    @ObservationIgnored private var ownMembership: HearthMembership?
    @ObservationIgnored private var householdMembership: HearthMembership?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var lastHouseholdCheck: Date?
    /// The app's Sign in with Apple button, for the "link your account" step.
    @ObservationIgnored private(set) var signInButton: (() -> AnyView)?

    private static let log = Logger(subsystem: "com.stephenwarren.hearth", category: "purchases")

    private init() {}

    /// Call once at launch. `accessToken` returns the Hearth API token when someone is signed in.
    func configure(
        app: HearthApp,
        apiKey: String,
        apiBaseURL: URL? = nil,
        accessToken: (@MainActor () async -> String?)? = nil,
        signInButton: (() -> AnyView)? = nil
    ) {
        guard !isConfigured else { return }
        self.app = app
        self.apiBaseURL = apiBaseURL
        self.accessToken = accessToken
        self.signInButton = signInButton
        isConfigured = true
        if previewUnlocked { return }

        #if DEBUG
        Purchases.logLevel = .warn
        #endif
        let userID = HearthAccounts.session()?.userID
        isSignedIn = userID != nil
        Purchases.configure(withAPIKey: apiKey, appUserID: userID)

        streamTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.apply(info)
            }
        }
        Hearth.startObservingChanges()
        changeObserver = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.followSignIn() }
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        Task {
            await refresh()
            await loadPlans()
        }
    }

    // MARK: Who's signed in

    /// Matches RevenueCat's customer to the shared Hearth sign-in.
    func followSignIn() async {
        guard isConfigured, !previewUnlocked else { return }
        let userID = HearthAccounts.session()?.userID
        isSignedIn = userID != nil
        do {
            if let userID, Purchases.shared.appUserID != userID {
                let (info, _) = try await Purchases.shared.logIn(userID)
                apply(info)
                await refreshHousehold(force: true)
            } else if userID == nil, !Purchases.shared.isAnonymous {
                apply(try await Purchases.shared.logOut())
                householdMembership = nil
                recompute()
            }
        } catch {
            Self.log.error("Couldn't follow the Hearth sign-in: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Status

    func refresh() async {
        guard isConfigured, !previewUnlocked else { return }
        await followSignIn()
        if let info = try? await Purchases.shared.customerInfo() { apply(info) }
        await refreshHousehold(force: false)
    }

    private func apply(_ info: CustomerInfo) {
        managementURL = info.managementURL
        let hearth = info.entitlements[HearthEntitlement.hearthPlus]
        var own = info.entitlements[HearthEntitlement.plan(for: app)]
        if app == .bigtable, own?.isActive != true, let legacy = info.entitlements[HearthEntitlement.legacyBigTablePro], legacy.isActive {
            own = legacy
        }
        let active = [hearth, own].compactMap { $0 }.first { $0.isActive }
        if let active {
            let kind: HearthPlan.Kind = active.identifier == HearthEntitlement.hearthPlus ? .hearthPlus : .app
            ownMembership = HearthMembership(
                kind: kind,
                term: Self.term(of: active.productIdentifier),
                source: active.ownershipType == .familyShared ? .familySharing : .own,
                expiresAt: active.expirationDate,
                willRenew: active.willRenew,
                isTrial: active.periodType == .trial
            )
            billingIssueUntil = active.billingIssueDetectedAt != nil ? active.expirationDate : nil
        } else {
            ownMembership = nil
            billingIssueUntil = nil
        }
        recompute()
    }

    private func recompute() {
        // Your own plan wins; Hearth+ from the household beats your own single-app plan.
        if let own = ownMembership, own.kind == .hearthPlus || householdMembership?.kind != .hearthPlus {
            membership = own
        } else {
            membership = householdMembership ?? ownMembership
        }
    }

    private static func term(of productID: String) -> HearthPlan.Term? {
        if productID.hasSuffix(".monthly") { return .monthly }
        if productID.hasSuffix(".annual") || productID.hasSuffix(".yearly") { return .annual }
        if productID.hasSuffix(".lifetime") { return .lifetime }
        return nil
    }

    // MARK: The household's plan

    private nonisolated struct ServerEntitlements: Decodable {
        nonisolated struct Item: Decodable {
            var id: String
            var expiresAt: String?
            var source: String
        }
        var entitlements: [Item]
        var hearthPlus: Bool
        var apps: [String: Bool]
    }

    /// Members of a household get the organizer's plan, whatever the household's size.
    private func refreshHousehold(force: Bool) async {
        guard let apiBaseURL, let accessToken, isSignedIn else {
            householdMembership = nil
            recompute()
            return
        }
        if !force, let last = lastHouseholdCheck, Date.now.timeIntervalSince(last) < 600 { return }
        guard let token = await accessToken() else { return }
        var request = URLRequest(url: apiBaseURL.appending(path: "v1/me/entitlements"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let result = try JSONDecoder().decode(ServerEntitlements.self, from: data)
            lastHouseholdCheck = .now
            let fromHousehold = result.entitlements.filter { $0.source == "household" }
            let ownKey = HearthEntitlement.plan(for: app)
            let match = fromHousehold.first { $0.id == HearthEntitlement.hearthPlus } ?? fromHousehold.first { $0.id == ownKey }
            householdMembership = match.map { item in
                HearthMembership(
                    kind: item.id == HearthEntitlement.hearthPlus ? .hearthPlus : .app,
                    term: nil,
                    source: .household,
                    expiresAt: item.expiresAt.flatMap(Self.date(fromISO:)),
                    willRenew: true,
                    isTrial: false
                )
            }
            recompute()
        } catch {
            Self.log.error("Household plan check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func date(fromISO text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Prices

    func loadPlans() async {
        guard isConfigured, !previewUnlocked else { return }
        plansState = .loading
        do {
            let offerings = try await Purchases.shared.offerings()
            guard let offering = offerings.current ?? offerings.all["default"] else {
                plansState = .unavailable
                return
            }
            var found: [String: Package] = [:]
            var app: [HearthPlan] = []
            var hearth: [HearthPlan] = []
            let eligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(packages: offering.availablePackages)
            for package in offering.availablePackages {
                guard let plan = Self.plan(for: package, eligible: eligibility[package]?.status != .ineligible) else { continue }
                found[package.identifier] = package
                if plan.kind == .hearthPlus { hearth.append(plan) } else { app.append(plan) }
            }
            if let tipOffering = offerings.all["tips"] {
                tips = tipOffering.availablePackages.map { package in
                    found[package.identifier] = package
                    return HearthPlan(id: package.identifier, kind: .app, term: .lifetime, price: package.storeProduct.localizedPriceString, priceValue: package.storeProduct.price, perMonth: nil, trialDays: nil, eligibleForTrial: false)
                }.sorted { $0.priceValue < $1.priceValue }
            }
            let order: [HearthPlan.Term] = [.annual, .monthly, .lifetime]
            appPlans = app.sorted { order.firstIndex(of: $0.term)! < order.firstIndex(of: $1.term)! }
            hearthPlans = hearth.sorted { order.firstIndex(of: $0.term)! < order.firstIndex(of: $1.term)! }
            packages = found
            plansState = (appPlans.isEmpty && hearthPlans.isEmpty) ? .unavailable : .loaded
        } catch {
            Self.log.error("Offerings failed: \(error.localizedDescription, privacy: .public)")
            plansState = .unavailable
        }
    }

    private static func plan(for package: Package, eligible: Bool) -> HearthPlan? {
        let product = package.storeProduct
        let id = package.identifier
        let kind: HearthPlan.Kind
        let term: HearthPlan.Term
        switch id {
        case "hearth_monthly": (kind, term) = (.hearthPlus, .monthly)
        case "hearth_annual": (kind, term) = (.hearthPlus, .annual)
        case "hearth_lifetime": (kind, term) = (.hearthPlus, .lifetime)
        default:
            switch package.packageType {
            case .monthly: (kind, term) = (.app, .monthly)
            case .annual: (kind, term) = (.app, .annual)
            default: return nil
            }
        }
        var trialDays: Int?
        if let intro = product.introductoryDiscount, intro.paymentMode == .freeTrial {
            let period = intro.subscriptionPeriod
            switch period.unit {
            case .day: trialDays = period.value
            case .week: trialDays = period.value * 7
            case .month: trialDays = period.value * 30
            case .year: trialDays = period.value * 365
            @unknown default: trialDays = nil
            }
        }
        return HearthPlan(
            id: id,
            kind: kind,
            term: term,
            price: product.localizedPriceString,
            priceValue: product.price,
            perMonth: term == .annual ? product.localizedPricePerMonth : nil,
            trialDays: trialDays,
            eligibleForTrial: eligible
        )
    }

    /// "Save 36%" on a yearly plan, against twelve months of the monthly one.
    func savings(for plan: HearthPlan) -> String? {
        guard plan.term == .annual else { return nil }
        let pool = plan.kind == .hearthPlus ? hearthPlans : appPlans
        guard let monthly = pool.first(where: { $0.term == .monthly }), monthly.priceValue > 0 else { return nil }
        let yearOfMonths = NSDecimalNumber(decimal: monthly.priceValue * 12).doubleValue
        let percent = Int((1 - NSDecimalNumber(decimal: plan.priceValue).doubleValue / yearOfMonths) * 100)
        return percent > 0 ? "Save \(percent)%" : nil
    }

    // MARK: Buying

    func purchase(_ plan: HearthPlan) async -> PurchaseOutcome {
        guard let package = packages[plan.id] else { return .failed("This plan isn't available right now.") }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return .cancelled }
            apply(result.customerInfo)
            return .purchased
        } catch let error as ErrorCode {
            switch error {
            case .purchaseCancelledError: return .cancelled
            case .paymentPendingError: return .pending
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func restore() async -> RestoreOutcome {
        do {
            apply(try await Purchases.shared.restorePurchases())
            await refreshHousehold(force: true)
            return isUnlocked ? .restored : .nothing
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Apple's Manage Subscriptions sheet, or Settings when that can't show.
    func manageSubscription() async {
        do {
            try await Purchases.shared.showManageSubscriptions()
        } catch {
            if let url = managementURL ?? URL(string: "https://apps.apple.com/account/subscriptions") {
                await UIApplication.shared.open(url)
            }
        }
    }

    func redeemCode() {
        Purchases.shared.presentCodeRedemptionSheet()
    }
}
