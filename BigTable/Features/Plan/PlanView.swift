import Foundation
import StoreKit
import SwiftUI
import UIKit

/// The Plan tab: the week strip, tonight's dinner, the selected day's breakfast, lunch and
/// dinner, and how many meals are left to fill (which the AI planner can do). Pull to refresh;
/// the plan also refreshes when the app comes back to the front.
struct PlanView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @Environment(\.accent) private var accent

    @AppStorage(SettingsKey.cookedCount) private var cookedCount = 0
    @AppStorage(SettingsKey.reviewPrompted) private var reviewPrompted = false

    @State private var store = PlanStore.shared
    @State private var selectedDay: DayOfWeek = PlanDates.day(for: .now)
    @State private var sheet: PlanSheet?
    @State private var pendingSwitch: PlanSheet?
    /// The recipes beside the week when the iPhone Duo is open wide (PlanWeekWide.swift).
    @State private var shelf = RecipeStore(collection: .all, pageSize: 20)
    @Environment(\.hearthDuoPose) private var pose

    /// Asks for an App Store rating after this many meals are marked cooked.
    private static let reviewAfterCooked = 3

    private var weekStart: String { router.weekStart }
    private var planner: PlannerResponse? { store.planner(weekStart) }
    private var selectedISO: String { PlanDates.iso(weekStart: weekStart, day: selectedDay) }
    private var isPastDay: Bool { selectedISO < PlanDates.todayISO }
    private var canManage: Bool { model.canManagePlan }

    var body: some View {
        layout
        .refreshable {
            await KitchenStore.shared.syncNow()
            await store.load(weekStart, force: true)
        }
        // The family changed the plan on another phone.
        .onChange(of: KitchenStore.shared.revision) { Task { await store.load(weekStart, force: true) } }
        .task(id: weekStart) { await store.load(weekStart) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.load(weekStart, force: true) }
        }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
                .tint(accent)
        }
        .alert(switchTitle, isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } })) {
            Button("Switch", role: .destructive) {
                sheet = pendingSwitch
                pendingSwitch = nil
            }
            Button("Cancel", role: .cancel) { pendingSwitch = nil }
        } message: {
            Text(switchMessage)
        }
        .errorAlert($store.actionError, title: "Couldn't update the plan")
        .toolbar {
            // Plan with AI is in BigTable AI now: the ✨ in the shared toolbar (RootTabView).
            // Open wide: Add Meal on the rail, for the day shown on the week pane.
            if pose == .openWide, canManage, !isPastDay {
                ToolbarItem(placement: .topBarLeading) {
                    Group {
                        Button {
                            request(.recipePicker(PlanSlotRef(weekStart: weekStart, day: selectedDay, slot: .dinner), .entree))
                        } label: {
                            Label("Add Meal", systemImage: "plus")
                        }
                    }
                    .tint(.white)
                }
            }
        }
        .sensoryFeedback(.success, trigger: cookedCount)
        .bigTableToolbar()
    }

    // MARK: Layout

    /// One column of the plan everywhere, except on an iPhone Duo open wide (the inner display
    /// in landscape): there, recipes on the leading pane and the week on the trailing pane.
    @ViewBuilder
    private var layout: some View {
        if pose == .openWide {
            HearthFoldSplit(axes: .horizontal) {
                PlanRecipeShelf(store: shelf, weekStart: weekStart, canPlan: canManage && !isPastWeek) { recipe, day in
                    addDinner(recipe, on: day)
                }
                // The same color header as the week pane (the shelf's title is white).
                .background(alignment: .top) { HeaderGradient() }
                .background(Color(.systemGroupedBackground))
            } secondary: {
                BigTableScreen(title: "Plan") {
                    planSections(showsNights: true)
                }
            }
        } else {
            BigTableScreen(title: "Plan") {
                planSections(showsNights: false)
            }
        }
    }

    private var isPastWeek: Bool { ISODay.adding(days: 6, to: weekStart) < PlanDates.todayISO }

    @ViewBuilder
    private func planSections(showsNights: Bool) -> some View {
        // BigTable Plus or Hearth+ couldn't renew: update the payment method (shows nothing
        // otherwise).
        HearthBillingBanner()

        if !canManage {
            Label("View only. \(organizerName) manages this plan.", systemImage: "eye")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }

        PlanWeekStrip(
            weekStart: weekStart,
            selectedDay: $selectedDay,
            planner: planner,
            onShiftWeek: { delta in
                router.weekStart = ISODay.adding(days: 7 * delta, to: weekStart)
            },
            onToday: {
                router.weekStart = PlanDates.currentWeekStart
                selectedDay = PlanDates.day(for: .now)
            }
        )
        .hearthTourTarget(BigTableTour.plan)

        // Open wide: the week's nights, where recipes from the shelf are dropped.
        if showsNights, let planner {
            PlanNightsCard(
                weekStart: weekStart,
                planner: planner,
                canManage: canManage,
                selectedDay: $selectedDay,
                onDrop: { id, day in dropRecipe(id, on: day) }
            )
        }

        if let planner {
            dayContent(planner)
        } else if let error = store.loadErrors[weekStart] {
            RetryCard(message: error) {
                Task { await store.load(weekStart, force: true) }
            }
        } else {
            LoadingCard(title: "Loading the plan…")
        }
    }

    /// A recipe dragged from the shelf onto a night: planned as that night's dinner.
    private func dropRecipe(_ id: String, on day: DayOfWeek) -> Bool {
        guard let recipe = shelf.recipes.first(where: { $0.id == id }) else { return false }
        addDinner(recipe, on: day)
        return true
    }

    private func addDinner(_ recipe: RecipeSummary, on day: DayOfWeek) {
        guard canManage else { return }
        let ref = PlanSlotRef(weekStart: weekStart, day: day, slot: .dinner)
        // A night out is replaced only after asking (as the recipe picker does).
        guard store.slot(ref).dineOut == nil else {
            store.actionError = "\(ref.title.capitalized) is planned as Dine Out. Open the day to change it."
            return
        }
        withAnimation(.snappy) { selectedDay = day }
        Task { await store.addRecipe(recipe, role: .entree, to: ref) }
    }

    private var organizerName: String {
        model.householdName.isEmpty ? "Your household organizer" : model.householdName
    }

    // MARK: The day

    @ViewBuilder
    private func dayContent(_ planner: PlannerResponse) -> some View {
        let isToday = selectedISO == PlanDates.todayISO

        if isToday {
            let dinnerRef = PlanSlotRef(weekStart: weekStart, day: selectedDay, slot: .dinner)
            PlanTonightCard(
                dinner: planner.slot(selectedDay, .dinner),
                faces: model.faces,
                canManage: canManage,
                onOpen: { openTonight(dinnerRef, planner.slot(selectedDay, .dinner)) },
                onToggleCooked: { toggleCompleted(dinnerRef) },
                onAdd: { request(.recipePicker(dinnerRef, .entree)) }
            )
        }

        SectionTitle(PlanDates.dayTitle(iso: selectedISO)) {
            if isToday {
                Text(ISODay.date(from: selectedISO)?.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) ?? "")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, isToday ? 4 : 0)

        ForEach(MealSlotType.allCases) { slot in
            let ref = PlanSlotRef(weekStart: weekStart, day: selectedDay, slot: slot)
            PlanSlotCard(
                ref: ref,
                slotData: planner.slot(selectedDay, slot),
                canManage: canManage,
                isPast: isPastDay,
                faces: model.faces,
                onRequest: request,
                onToggleCompleted: { toggleCompleted(ref) }
            )
        }

        mealsToFill(planner)
    }

    /// "4 meals to fill" for the rest of this week, opening the AI planner.
    @ViewBuilder
    private func mealsToFill(_ planner: PlannerResponse) -> some View {
        let today = PlanDates.todayISO
        let remaining = DayOfWeek.allCases.filter { PlanDates.iso(weekStart: weekStart, day: $0) >= today }
        let empty = remaining.reduce(0) { total, day in
            total + MealSlotType.allCases.filter { planner.slot(day, $0).isEmpty }.count
        }
        if empty > 0, canManage, model.canUseAIPlan {
            Button {
                router.present(.aiPlan)
            } label: {
                LinkCard(
                    symbol: "sparkles",
                    color: accent,
                    title: empty == 1 ? "1 meal to fill" : "\(empty) meals to fill",
                    detail: remaining.count == 7 ? "Plan this week with AI" : "Plan the rest of the week with AI"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        } else if empty == 0, !remaining.isEmpty {
            Label("Every meal is planned for the rest of the week.", systemImage: "checkmark.seal")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func openTonight(_ ref: PlanSlotRef, _ dinner: PlannerSlot) {
        if dinner.dineOut != nil {
            sheet = .dineOutDetail(ref)
        } else if let item = dinner.recipeItems.first(where: { $0.recipeId != nil }), let id = item.recipeId {
            router.present(.recipe(id: id, versionID: item.recipeVersionId))
        } else if canManage, dinner.recipeItems.isEmpty, dinner.customMeal != nil {
            sheet = .customMeal(ref)
        }
    }

    // MARK: Actions

    /// Opens a sheet, first asking before a recipe replaces a night out or the other way round.
    private func request(_ next: PlanSheet) {
        guard canManage else { return }
        let current = store.slot(next.ref)
        switch next {
        case .recipePicker, .customMeal:
            if current.dineOut != nil {
                pendingSwitch = next
                return
            }
        case .dineOut:
            if !current.recipeItems.isEmpty {
                pendingSwitch = next
                return
            }
        case .dineOutDetail, .snacks:
            break
        }
        sheet = next
    }

    private var switchTitle: String {
        if case .dineOut = pendingSwitch { return "Switch to Dine Out?" }
        return "Switch from Dine Out?"
    }

    private var switchMessage: String {
        if case .dineOut = pendingSwitch {
            return "This meal already has recipes. Choosing a restaurant removes them."
        }
        return "This meal is planned as Dine Out. Adding a meal at home removes the restaurant."
    }

    private func toggleCompleted(_ ref: PlanSlotRef) {
        guard canManage else { return }
        let wasCompleted = store.slot(ref).completed
        Task {
            let saved = await store.setCompleted(!wasCompleted, in: ref)
            if saved, !wasCompleted { await countCooked() }
        }
    }

    /// After a few meals are cooked, asks once for an App Store rating.
    private func countCooked() async {
        cookedCount += 1
        // Screenshot mode (Debug) never asks.
        guard cookedCount >= Self.reviewAfterCooked, !reviewPrompted, !ScreenshotMode.isOn else { return }
        reviewPrompted = true
        try? await Task.sleep(for: .milliseconds(800))
        requestReview()
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: PlanSheet) -> some View {
        switch sheet {
        case .recipePicker(let ref, let role):
            RecipePickerView { recipe in
                self.sheet = nil
                Task { await store.addRecipe(recipe, role: role, to: ref) }
            }
        case .customMeal(let ref):
            PlanCustomMealView(title: ref.title, initial: store.slot(ref).recipeItems.isEmpty ? (store.slot(ref).customMeal ?? "") : "") { text in
                Task { await store.setCustomMeal(text, in: ref) }
            }
        case .dineOut(let ref):
            PlanDineOutView(ref: ref, current: store.slot(ref).dineOut) { dineOut in
                Task { await store.setDineOut(dineOut, in: ref) }
            }
        case .dineOutDetail(let ref):
            PlanDineOutDetailView(
                ref: ref,
                dineOut: store.slot(ref).dineOut,
                canManage: canManage,
                onChange: { self.sheet = .dineOut(ref) },
                onRemove: { Task { await store.removeDineOut(in: ref) } }
            )
        case .snacks(let ref):
            PlanSnackPickerView(title: ref.title) { snacks in
                Task { await store.addSnacks(snacks, to: ref) }
            }
        }
    }
}

/// Tonight's dinner, big: its photo, what it is, who's eating and a check for when it's
/// cooked. When nothing's planned, a nudge to plan it.
struct PlanTonightCard: View {
    var dinner: PlannerSlot
    var faces: [Face]
    var canManage: Bool
    var onOpen: () -> Void
    var onToggleCooked: () -> Void
    var onAdd: () -> Void

    @Environment(\.accent) private var accent

    private var excluded: Set<String> { Set(dinner.excludedMembers) }
    private var headline: String {
        if let dineOut = dinner.dineOut { return PlanDineOutFormat.displayName(dineOut) }
        return dinner.title.isEmpty ? "Dinner" : dinner.title
    }
    private var eating: Int { faces.filter { !excluded.contains($0.name) }.count }

    var body: some View {
        if dinner.isEmpty {
            emptyCard
        } else {
            plannedCard
        }
    }

    private var plannedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                photo
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TONIGHT")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(headline)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(16)
            }
            .contentShape(.rect)
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens tonight's dinner")

            HStack(spacing: 10) {
                if !faces.isEmpty {
                    FacePile(faces: Array(faces.prefix(6)), skipped: excluded, size: 28)
                    Text("\(eating) eating")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if canManage {
                    Button(action: onToggleCooked) {
                        HStack(spacing: 8) {
                            RoundCheck(isOn: dinner.completed, color: MealSlotType.dinner.color, size: 24)
                            Text(dinner.completed ? "Cooked" : "Mark cooked")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else if dinner.completed {
                    Label("Cooked", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MealSlotType.dinner.color)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 22))
    }

    @ViewBuilder
    private var photo: some View {
        if let url = PlanSlotText.primaryImage(dinner) {
            RecipePhoto(url: url, cornerRadius: 0, symbolSize: 40)
        } else if let dineOut = dinner.dineOut {
            ZStack {
                accent.opacity(0.18)
                PlanDineOutLogo(url: dineOut.logoUrl, size: 84)
            }
        } else {
            RecipePhoto(url: nil, cornerRadius: 0, symbolSize: 40)
        }
    }

    private var emptyCard: some View {
        Card {
            HStack(spacing: 14) {
                IconTile(symbol: "moon.stars", color: MealSlotType.dinner.color, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tonight").font(.headline)
                    Text("Nothing's planned for dinner yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if canManage {
                    Button("Add", action: onAdd)
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel("Add a recipe for tonight's dinner")
                }
            }
        }
    }
}

/// Type a meal that has no recipe: "Leftovers", "Cereal", "Grandma's".
struct PlanCustomMealView: View {
    var title: String
    var initial: String
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private static let limit = 120

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Leftovers, tacos, breakfast for dinner…", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text("A meal without a recipe. It shows on the plan as you write it.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Save", action: save)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: text) { _, value in
                if value.count > Self.limit { text = String(value.prefix(Self.limit)) }
            }
            .onAppear {
                text = initial
                focused = true
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
