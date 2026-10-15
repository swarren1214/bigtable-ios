import Foundation
import SwiftUI
import UIKit

/// BigTable Pro: what it adds over Starter, the annual and monthly plans (annual first, with
/// what it saves), Subscribe, Restore Purchases, and the terms. Closes itself once Pro is
/// active. Someone who joined another household sees that the organizer manages the plan.
struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accent) private var accent
    @State private var selectedPlanID: String?
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var plansMessage: String?

    private var subscriptions: Subscriptions { Subscriptions.shared }

    static let proFeatures = [
        PaywallFeature(symbol: "sparkles", title: "AI meal plans", detail: "A week of meals for everyone at the table, planned around restrictions and favorites."),
        PaywallFeature(symbol: "wand.and.stars", title: "AI grocery lists", detail: "Built from the plan, sorted by aisle, with amounts and a cost estimate."),
        PaywallFeature(symbol: "doc.viewfinder", title: "Recipe scanning", detail: "Photograph a cookbook page or recipe card."),
        PaywallFeature(symbol: "link", title: "Import from the web", detail: "Paste a link and BigTable writes the recipe."),
        PaywallFeature(symbol: "photo", title: "Recipe photos", detail: "Add your own photos to recipes."),
    ]

    static let starterFeatures = [
        "Manual meal planning",
        "The recipe library",
        "Your own recipes",
        "AI recipe images",
        "Household setup and sharing",
        "Grocery list by hand",
    ]

    private var selectedPlan: Subscriptions.Plan? {
        subscriptions.plans.first { $0.id == selectedPlanID } ?? subscriptions.plans.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if !model.isOrganizer {
                        managedCard
                    } else if subscriptions.isPro {
                        activeCard
                    } else {
                        planPicker
                    }
                    featureCards
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("BigTable Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.isOrganizer && !subscriptions.isPro && !subscriptions.plans.isEmpty {
                    subscribeBar
                }
            }
        }
        .task {
            await subscriptions.loadPlans()
            if subscriptions.plans.isEmpty {
                plansMessage = subscriptions.lastError ?? "Plans aren't available right now. Try again later."
                subscriptions.lastError = nil
            } else {
                plansMessage = nil
                if selectedPlanID == nil { selectedPlanID = subscriptions.plans.first?.id }
            }
        }
        .onChange(of: subscriptions.isPro) { _, isPro in
            if isPro { dismiss() }
        }
        .errorAlert($errorMessage)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 12) {
            OnboardingSymbolIcon(symbol: "sparkles", size: 76)
            Text("Let BigTable plan the week")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Pro plans meals for the whole family and builds the grocery list, so dinner is one less thing to figure out.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var managedCard: some View {
        Card(padding: 20) {
            VStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text("Managed by your organizer")
                    .font(.headline)
                Text(model.householdName.isEmpty
                     ? "Your household's organizer manages BigTable Pro. Pro features they turn on for you come with the household."
                     : "\(model.householdName)'s organizer manages BigTable Pro. Pro features they turn on for you come with the household.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var activeCard: some View {
        Card(padding: 20) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color(hex: 0x1E9E6A))
                Text("You're on BigTable Pro")
                    .font(.headline)
                if let date = subscriptions.expirationDate {
                    Text(subscriptions.willRenew
                         ? "Renews \(date.formatted(date: .abbreviated, time: .omitted))."
                         : "Ends \(date.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button {
                    openURL(subscriptions.managementURL ?? ProfileLinks.manageSubscriptions)
                } label: {
                    Text("Manage Subscription").frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var planPicker: some View {
        if subscriptions.plans.isEmpty {
            if let plansMessage {
                RetryCard(message: plansMessage) {
                    Task {
                        self.plansMessage = nil
                        await subscriptions.loadPlans()
                        if subscriptions.plans.isEmpty {
                            self.plansMessage = subscriptions.lastError ?? "Plans aren't available right now. Try again later."
                            subscriptions.lastError = nil
                        } else {
                            selectedPlanID = subscriptions.plans.first?.id
                        }
                    }
                }
            } else {
                LoadingCard(title: "Loading plans…")
            }
        } else {
            VStack(spacing: 12) {
                ForEach(subscriptions.plans) { plan in
                    planCard(plan)
                }
            }
        }
    }

    private func planCard(_ plan: Subscriptions.Plan) -> some View {
        let isSelected = selectedPlan?.id == plan.id
        return Button {
            selectedPlanID = plan.id
        } label: {
            HStack(alignment: .top, spacing: 14) {
                RoundCheck(isOn: isSelected, color: accent, size: 26)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plan.title).font(.headline)
                        if plan.isAnnual, let savings = annualSavingsPercent {
                            TagLabel(text: "Save \(savings)%", color: accent)
                        }
                    }
                    Text(plan.isAnnual ? "\(plan.price) a year" : "\(plan.price) a month")
                        .font(.subheadline)
                    if let perMonth = plan.perMonth {
                        Text(perMonth)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let trial = plan.trial {
                        Text("Starts with \(trial)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(isSelected ? accent : Color.clear, lineWidth: 2))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var featureCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text("Pro").font(.headline)
                        ProBadge()
                        Spacer()
                        Text("Everything in Starter, plus")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Self.proFeatures) { feature in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: feature.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 26)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title).font(.subheadline.weight(.semibold))
                                Text(feature.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Starter").font(.headline)
                        Spacer()
                        Text("Free")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Self.starterFeatures, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            if model.isOrganizer && !subscriptions.isPro {
                Button {
                    Task { await restore() }
                } label: {
                    if isRestoring {
                        ProgressView()
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .disabled(isRestoring || isPurchasing)
            }
            HStack(spacing: 20) {
                Button("Terms of Use") { openURL(ProfileLinks.terms) }
                Button("Privacy Policy") { openURL(ProfileLinks.privacy) }
            }
            .font(.footnote)
            Text("Payment is charged to your Apple Account. Subscriptions renew automatically unless canceled at least 24 hours before the end of the period. Manage or cancel anytime in your Apple Account's subscriptions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var subscribeBar: some View {
        VStack(spacing: 6) {
            Button {
                Task { await purchase() }
            } label: {
                Group {
                    if isPurchasing {
                        ProgressView().tint(.white)
                    } else {
                        Text(subscribeTitle)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(selectedPlan == nil || isPurchasing || isRestoring)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var subscribeTitle: String {
        guard let plan = selectedPlan else { return "Subscribe" }
        if plan.trial != nil { return "Start Free Trial" }
        return plan.isAnnual ? "Subscribe for \(plan.price) a Year" : "Subscribe for \(plan.price) a Month"
    }

    /// How much less the annual plan costs than twelve months, from the store's prices.
    private var annualSavingsPercent: Int? {
        guard let monthly = subscriptions.plans.first(where: { !$0.isAnnual }).flatMap({ Self.amount($0.price) }),
              let annual = subscriptions.plans.first(where: \.isAnnual).flatMap({ Self.amount($0.price) }),
              monthly > 0 else { return nil }
        let yearOfMonthly = monthly * 12
        let percent = Int(((yearOfMonthly - annual) / yearOfMonthly * 100).rounded())
        return percent > 0 ? percent : nil
    }

    /// The number in a localized price ("$55.99", "55,99 €").
    static func amount(_ price: String) -> Double? {
        guard let match = price.firstMatch(of: #/\d+(?:[.,]\d{1,2})?/#) else { return nil }
        return Double(match.output.replacingOccurrences(of: ",", with: "."))
    }

    // MARK: Actions

    private func purchase() async {
        guard let plan = selectedPlan else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        subscriptions.lastError = nil
        let isPro = await subscriptions.purchase(plan)
        if let message = subscriptions.lastError {
            subscriptions.lastError = nil
            errorMessage = message
        } else if isPro {
            dismiss()
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        subscriptions.lastError = nil
        await subscriptions.restore()
        if let message = subscriptions.lastError {
            subscriptions.lastError = nil
            errorMessage = message
        }
    }
}

/// A line in the Pro feature list.
nonisolated struct PaywallFeature: Identifiable, Hashable, Sendable {
    var symbol: String
    var title: String
    var detail: String
    var id: String { title }
}
