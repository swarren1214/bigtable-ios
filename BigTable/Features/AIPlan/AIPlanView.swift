import Foundation
import SwiftUI
import UIKit

/// The AI meal planner (Plan › sparkles, or "meals to fill"): say what the week needs, pick
/// the days and meals, how the recipes should be mixed, then preview what it plans before
/// adding it to the plan. Needs BigTable Plus or Hearth+ (the server's usage still sets the
/// AI limits); members need the organizer's OK.
struct AIPlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent

    @State private var store: AIPlanStore
    @State private var showsPreview = false
    @FocusState private var promptFocused: Bool

    /// Opened inside BigTable AI (the ✨ sheet) rather than as its own sheet: no navigation
    /// stack or Close of its own (Back returns to Ask), and finishing closes the whole sheet.
    private let embedded: Bool

    init(embedded: Bool = false) {
        self.embedded = embedded
        _store = State(initialValue: AIPlanStore(weekStart: AppRouter.shared.weekStart))
    }

    private var usage: UsageCheckResponse? { model.usage }
    /// AI meal plans are part of BigTable Plus and Hearth+.
    private var isLocked: Bool { !model.hasPro }
    /// The server says this account can't make AI requests right now (this month's are used up).
    private var isUsedUp: Bool { usage.map { !$0.canMakeRequest } ?? false }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        .overlay {
            if store.phase.isBusy {
                AIPlanProgressOverlay(phase: store.phase)
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: store.phase)
        .errorAlert($store.error, title: "Couldn't plan your meals")
        .interactiveDismissDisabled(store.phase.isBusy)
        .hearthPaywall(isPresented: $store.showsPaywall, feature: Self.paywallFeature)
    }

    /// Done: the plan was added. Closes the planner, or all of BigTable AI around it.
    private func finish() {
        if embedded {
            AppRouter.shared.sheet = nil
        } else {
            dismiss()
        }
    }

    private var content: some View {
        Group {
            if !model.isSignedIn {
                SignInPrompt(reason: .aiPlan)
            } else if model.canUseAIPlan && model.canManagePlan {
                form
            } else {
                notAllowed
            }
        }
        .navigationTitle(embedded ? "Plan the Week" : "Plan with AI")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(store.phase.isBusy)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                        .disabled(store.phase.isBusy)
                }
            }
        }
        .navigationDestination(isPresented: $showsPreview) {
            AIPlanPreviewView(store: store, onApplied: { finish() }, onRegenerate: { Task { await generate() } })
        }
        .task(id: model.isSignedIn) { await model.refreshUsage() }
        .task(id: "\(store.startISO)|\(store.endISO)") { await store.loadBaselines() }
        .task {
            // Screenshot mode (Debug): a filled-in request, and for -Screen aipreview, its preview.
            guard ScreenshotMode.isOn else { return }
            store.prompt = "Soccer Tuesday and Thursday, so quick dinners. Something cozy on Sunday."
            store.quickTags = ["busy_weekdays", "under_30"]
            store.overwriteExisting = false
            if ScreenshotMode.screen == .aipreview {
                try? await Task.sleep(for: .milliseconds(600))
                await generate()
            }
        }
    }

    static let paywallFeature = HearthPaywallFeature(
        "AI meal plans",
        detail: "Plan a week of meals from your recipes and favorites, then build the grocery list from it.",
        symbol: "sparkles"
    )

    // MARK: Not allowed

    private var notAllowed: some View {
        ScrollView {
            VStack(spacing: 16) {
                EmptyCard(
                    symbol: "person.badge.key",
                    title: "Ask a parent",
                    message: "Kids in \(model.householdName.isEmpty ? "the household" : model.householdName) don't plan with AI. A parent can change your role in Profile › Household."
                )
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Form

    private var form: some View {
        Form {
            usageSection

            Section {
                TextField("Busy Tue + Thu, big Sunday dinner…", text: $store.prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .focused($promptFocused)
                FlowLayout(spacing: 8) {
                    ForEach(AIPlanQuickTag.all) { tag in
                        let isOn = store.quickTags.contains(tag.id)
                        Button {
                            if isOn { _ = store.quickTags.remove(tag.id) } else { _ = store.quickTags.insert(tag.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tag.symbol)
                                Text(tag.label).lineLimit(1)
                            }
                                .font(.subheadline.weight(.semibold))
                                .fixedSize()
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .foregroundStyle(isOn ? Color.white : Color.primary)
                                .background(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("What should we plan around?")
            }

            Section("Meal style") {
                Picker("Meal style", selection: $store.mealStyle) {
                    ForEach(MealStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                DatePicker(
                    "Starts",
                    selection: Binding(get: { store.startDate }, set: { store.setStart($0) }),
                    in: Calendar.current.startOfDay(for: .now)...,
                    displayedComponents: .date
                )
                DatePicker(
                    "Ends",
                    selection: Binding(get: { store.endDate }, set: { store.setEnd($0) }),
                    in: store.startDate...store.latestEndDate,
                    displayedComponents: .date
                )
            } header: {
                Text("Dates")
            } footer: {
                Text("Up to 7 days at a time.")
            }

            Section {
                ForEach(store.rangeDates, id: \.self) { iso in
                    AIPlanDayRow(store: store, iso: iso)
                }
            } header: {
                Text("Meals by day")
            } footer: {
                Text(store.selectedMealCount == 1 ? "1 meal selected." : "\(store.selectedMealCount) meals selected.")
            }

            if store.hasExistingMeals {
                Section {
                    Toggle("Replace meals already planned", isOn: $store.overwriteExisting)
                } footer: {
                    Text("Turn off to keep what's planned and only fill the empty meals.")
                }
            }

            Section {
                AIPlanRecipeMixControl(mix: $store.mix)
                    .padding(.vertical, 6)
            } header: {
                Text("Recipe mix")
            } footer: {
                Text("How much of the plan comes from each source.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { generateBar }
    }

    @ViewBuilder
    private var usageSection: some View {
        if isLocked {
            Section {
                HearthLockedCard(feature: Self.paywallFeature)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        } else if let usage {
            if isUsedUp {
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: "sparkles", color: accent, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("You've used this month's AI plans")
                                .font(.subheadline.weight(.semibold))
                            Text("Your AI allowance resets \(resetText(usage)).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: "sparkles", color: accent, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            if usage.isUnlimited {
                                Text("BigTable Plus").font(.subheadline.weight(.semibold))
                                Text("Plan as often as you like.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(usage.requestsUsed) of \(usage.requestsLimit) AI credits used")
                                    .font(.subheadline.weight(.semibold))
                                Text("Each planned day uses a credit. Resets \(resetText(usage)).")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if usage.isPro { ProBadge() }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func resetText(_ usage: UsageCheckResponse) -> String {
        guard let date = ISODay.timestamp(usage.resetsAt) else { return "soon" }
        return date.formatted(.dateTime.month(.wide).day())
    }

    private var generateBar: some View {
        VStack(spacing: 6) {
            Button {
                promptFocused = false
                Task { await generate() }
            } label: {
                Label(isLocked ? "See Plans" : "Generate Meal Plan", systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(store.selectedMealCount == 0 || store.phase.isBusy || (isUsedUp && !isLocked))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func generate() async {
        guard model.canUseAIPlan else { return }
        if isLocked {
            store.showsPaywall = true
            return
        }
        guard !isUsedUp else { return }
        if await store.generate(model: model, router: router) {
            showsPreview = true
        }
    }
}

/// One day in the range: on or off, and which of its meals to plan.
struct AIPlanDayRow: View {
    var store: AIPlanStore
    var iso: String

    var body: some View {
        let day = PlanDates.day(forISO: iso)
        let enabled = store.isEnabled(day)
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { enabled }, set: { _ in store.toggleDay(day) })) {
                Text(PlanDates.shortTitle(iso: iso))
                    .font(.body.weight(.semibold))
            }
            HStack(spacing: 8) {
                ForEach(MealSlotType.allCases) { slot in
                    Chip(title: slot.label, color: slot.color, isOn: enabled && store.isSelected(slot, on: day)) {
                        store.toggle(slot, on: day)
                    }
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.45)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shown while the planner works: the steps, with the current one spinning.
struct AIPlanProgressOverlay: View {
    var phase: AIPlanStore.Phase

    private var steps: [(phase: AIPlanStore.Phase, label: String)] {
        if phase == .applying {
            return [(.applying, "Adding meals to your plan")]
        }
        return [
            (.validating, "Checking your choices"),
            (.requesting, "Asking the planner"),
            (.drafting, "Building meals for your days"),
        ]
    }

    private func index(of phase: AIPlanStore.Phase) -> Int {
        steps.firstIndex { $0.phase == phase } ?? 0
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.2))
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text(phase == .applying ? "Saving your plan" : "Planning your meals")
                    .font(.title3.bold())
                ForEach(Array(steps.enumerated()), id: \.offset) { offset, step in
                    let current = index(of: phase)
                    HStack(spacing: 10) {
                        Group {
                            if offset < current {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if offset == current {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 22)
                        Text(step.label)
                            .font(.subheadline.weight(offset == current ? .semibold : .regular))
                            .foregroundStyle(offset > current ? .secondary : .primary)
                    }
                }
                Text("This can take up to a minute.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: 340, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .padding(24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
