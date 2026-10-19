import Foundation
import Observation

/// A quick preference chip in the AI planner ("Busy weekdays"); its id is what the API gets.
nonisolated struct AIPlanQuickTag: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var symbol: String

    /// The Expo app's set, in its order.
    static let all: [AIPlanQuickTag] = [
        AIPlanQuickTag(id: "busy_weekdays", label: "Busy weekdays", symbol: "figure.run"),
        AIPlanQuickTag(id: "sunday_dinner", label: "Big Sunday dinner", symbol: "fork.knife"),
        AIPlanQuickTag(id: "budget_week", label: "Budget week", symbol: "creditcard"),
        AIPlanQuickTag(id: "freezer_meals", label: "Freezer meals", symbol: "snowflake"),
        AIPlanQuickTag(id: "under_30", label: "Under 30 min", symbol: "bolt"),
    ]
}

/// One meal in the preview: what the AI picked and what it changes.
nonisolated struct AIPlanPreviewRow: Identifiable, Hashable, Sendable {
    nonisolated enum Change: Hashable, Sendable {
        /// Fills an empty slot.
        case new
        /// Replaces what was planned.
        case replaces
        /// Already planned and kept (overwrite was off).
        case keeps
        /// The same meal as before.
        case same
    }

    var isoDate: String
    var slot: MealSlotType
    var title: String
    var previousTitle: String?
    var imageUrl: String?
    var change: Change

    var id: String { "\(isoDate)|\(slot.rawValue)" }
}

/// A generated plan waiting for the person to add it.
nonisolated struct AIPlanPreview: Sendable {
    /// The request that made it.
    var request: MealPlanRequest
    var generatedPlan: [String: [String: String]]
    var generatedBy: String
    var rows: [AIPlanPreviewRow]
    /// Which recipe each planned title is (lowercased titles).
    var lookup: [String: MealPlanResponse.LookupEntry]

    var dates: [String] {
        var seen = Set<String>()
        return rows.map(\.isoDate).filter { seen.insert($0).inserted }
    }
}

/// Everything the AI meal planner sheet holds: the person's choices, the request in flight,
/// and the preview. The plan comes from the device's model or the API, which saves nothing;
/// adding writes exactly the previewed meals into the kitchen.
@MainActor
@Observable
final class AIPlanStore {
    nonisolated enum Phase: Equatable, Sendable {
        case idle, validating, requesting, drafting, applying

        var isBusy: Bool { self != .idle }
    }

    var prompt = ""
    var quickTags: Set<String> = []
    var mealStyle: MealStyle = .comfort
    /// The Expo app's default: half your recipes, a quarter each favorites and others.
    var mix = RecipeMix(mine: 50, favorites: 25, other: 25)
    private(set) var startDate: Date
    private(set) var endDate: Date
    /// Days of the week turned off in the range.
    var disabledDays: Set<DayOfWeek> = []
    /// Which meals to plan for each day of the week (all three by default).
    var mealsByDay: [DayOfWeek: Set<MealSlotType>] = Dictionary(uniqueKeysWithValues: DayOfWeek.allCases.map { ($0, Set(MealSlotType.allCases)) })
    var overwriteExisting = true
    private(set) var phase: Phase = .idle
    private(set) var preview: AIPlanPreview?
    var error: String?

    static let maxDays = 7

    @ObservationIgnored private let api = BigTableAPI.shared

    /// Defaults to the rest of the week the Plan tab shows (from today when it's this week).
    init(weekStart: String) {
        let today = PlanDates.todayISO
        let weekEnd = ISODay.adding(days: 6, to: weekStart)
        var start = weekStart < today ? today : weekStart
        var end = weekEnd
        if start > end {
            start = today
            end = today
        }
        startDate = ISODay.date(from: start) ?? .now
        endDate = ISODay.date(from: end) ?? .now
    }

    // MARK: Range

    var startISO: String { ISODay.string(from: startDate) }
    var endISO: String { ISODay.string(from: endDate) }
    var rangeDates: [String] { PlanDates.dates(from: startISO, to: endISO) }
    /// The weeks (Sundays) the range touches.
    var rangeWeeks: [String] {
        var seen = Set<String>()
        return rangeDates.compactMap { iso in
            let week = ISODay.weekStart(containing: ISODay.date(from: iso) ?? .now)
            return seen.insert(week).inserted ? week : nil
        }
    }

    var latestEndDate: Date {
        Calendar.current.date(byAdding: .day, value: Self.maxDays - 1, to: startDate) ?? startDate
    }

    /// Moves the start, keeping the range to at most a week and never in the past.
    func setStart(_ date: Date) {
        let day = Calendar.current.startOfDay(for: max(date, Calendar.current.startOfDay(for: .now)))
        startDate = day
        if endDate < day { endDate = day }
        if endDate > latestEndDate { endDate = latestEndDate }
    }

    func setEnd(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        endDate = min(max(day, startDate), latestEndDate)
    }

    // MARK: Meals

    func isEnabled(_ day: DayOfWeek) -> Bool { !disabledDays.contains(day) }

    func toggleDay(_ day: DayOfWeek) {
        if disabledDays.contains(day) {
            disabledDays.remove(day)
        } else {
            disabledDays.insert(day)
        }
    }

    func isSelected(_ slot: MealSlotType, on day: DayOfWeek) -> Bool {
        mealsByDay[day, default: []].contains(slot)
    }

    func toggle(_ slot: MealSlotType, on day: DayOfWeek) {
        var slots = mealsByDay[day, default: []]
        if slots.contains(slot) {
            slots.remove(slot)
        } else {
            slots.insert(slot)
        }
        mealsByDay[day] = slots
    }

    private func slots(for iso: String) -> [MealSlotType] {
        let day = PlanDates.day(forISO: iso)
        guard isEnabled(day) else { return [] }
        return MealSlotType.allCases.filter { isSelected($0, on: day) }
    }

    var selectedMealCount: Int {
        rangeDates.reduce(0) { $0 + slots(for: $1).count }
    }

    /// Something is already planned in the chosen days and meals.
    var hasExistingMeals: Bool {
        rangeDates.contains { iso in
            let week = ISODay.weekStart(containing: ISODay.date(from: iso) ?? .now)
            guard let planner = PlanStore.shared.planner(week) else { return false }
            let day = PlanDates.day(forISO: iso)
            return MealSlotType.allCases.contains { !planner.slot(day, $0).isEmpty }
        }
    }

    // MARK: Generating

    /// Makes sure the plan for the chosen days is loaded, to show what changes.
    func loadBaselines() async {
        for week in rangeWeeks {
            await PlanStore.shared.load(week)
        }
    }

    func makeRequest() -> MealPlanRequest {
        let dates = rangeDates
        let selectedDates = dates.filter { !slots(for: $0).isEmpty }
        // The API reads `selectedMeals` by day name (sunday…saturday), as the Expo app sent it.
        var selectedMeals: [String: [String]] = [:]
        for day in DayOfWeek.allCases {
            let inRange = dates.contains { PlanDates.day(forISO: $0) == day }
            selectedMeals[day.rawValue] = inRange && isEnabled(day)
                ? MealSlotType.allCases.filter { isSelected($0, on: day) }.map(\.rawValue)
                : []
        }
        let tags = AIPlanQuickTag.all.map(\.id).filter { quickTags.contains($0) }
        return MealPlanRequest(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            mealStyle: mealStyle,
            recipeMix: mix,
            quickTags: tags,
            selectedMeals: selectedMeals,
            weekStart: ISODay.weekStart(containing: startDate),
            selectedDates: selectedDates,
            startDate: startISO,
            endDate: endISO,
            overwriteExisting: overwriteExisting,
            previewOnly: true,
            generatedPlan: nil,
            generatedBy: nil,
            household: HearthHouseholdStore.shared.exists ? HearthHouseholdStore.shared.aiContext() : nil,
            myRecipes: KitchenStore.shared.ownSummaries().map { recipe in
                MealPlanRequest.MyRecipe(id: recipe.id, title: recipe.title, tags: recipe.tags, minutes: recipe.totalMinutes > 0 ? recipe.totalMinutes : nil)
            }
        )
    }

    /// What goes to the planner: with "replace" off, meals already planned are left out, so
    /// only empty slots are filled (and counted).
    private func plannerRequest(from request: MealPlanRequest) -> MealPlanRequest {
        guard !(request.overwriteExisting ?? true) else { return request }
        var trimmed = request
        var meals = request.selectedMeals ?? [:]
        var keptDates: [String] = []
        for iso in request.selectedDates ?? [] {
            let day = PlanDates.day(forISO: iso)
            let week = ISODay.weekStart(containing: ISODay.date(from: iso) ?? .now)
            let baseline = PlanStore.shared.planner(week)
            let open = (meals[day.rawValue] ?? []).filter { name in
                guard let slot = MealSlotType(rawValue: name) else { return false }
                return baseline.map { $0.slot(day, slot).isEmpty } ?? true
            }
            meals[day.rawValue] = open
            if !open.isEmpty { keptDates.append(iso) }
        }
        trimmed.selectedMeals = meals
        trimmed.selectedDates = keptDates
        return trimmed
    }

    /// Asks for a preview. Returns true when there's one to show. A usage limit opens the
    /// paywall.
    func generate(model: AppModel, router: AppRouter) async -> Bool {
        guard selectedMealCount > 0 else {
            error = "Choose at least one day and meal to plan."
            return false
        }
        phase = .validating
        await loadBaselines()
        try? await Task.sleep(for: .milliseconds(250))

        let request = makeRequest()
        let sent = plannerRequest(from: request)
        guard !(sent.selectedDates ?? []).isEmpty else {
            phase = .idle
            error = "Those meals are already planned. Turn on Replace to plan them again."
            return false
        }
        phase = .requesting
        // The request takes a while; move the progress along so it doesn't look stuck.
        let stepper = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.phase == .requesting else { return }
            self.phase = .drafting
        }
        defer { stepper.cancel() }

        do {
            // Plan on the device when it can; otherwise the API plans it (saving nothing).
            let plan: [String: [String: String]]
            let generatedBy: String
            var lookup: [String: MealPlanResponse.LookupEntry]
            if let onDevice = await OnDeviceMealPlanner.plan(for: sent) {
                plan = onDevice.plan
                generatedBy = "anthropic"
                lookup = onDevice.lookup
            } else {
                let response = try await api.generateMealPlan(sent)
                model.updateUsage(response.usage)
                guard let generated = response.generatedPlan else {
                    phase = .idle
                    error = "The planner didn't send back any meals. Try again."
                    return false
                }
                plan = generated
                generatedBy = response.generatedBy
                lookup = response.recipeLookup ?? [:]
            }
            phase = .drafting
            // The family's own recipes, by title, whatever the planner said.
            for recipe in KitchenStore.shared.ownSummaries() {
                lookup[recipe.title.lowercased()] = MealPlanResponse.LookupEntry(recipeId: recipe.id, imageUrl: recipe.imageUrl, bucket: "mine")
            }
            preview = AIPlanPreview(
                request: request,
                generatedPlan: plan,
                generatedBy: generatedBy,
                rows: makeRows(request: request, plan: plan, lookup: lookup),
                lookup: lookup
            )
            try? await Task.sleep(for: .milliseconds(200))
            phase = .idle
            return true
        } catch {
            phase = .idle
            handle(error, router: router)
            return false
        }
    }

    /// Adds the previewed meals to the plan (the kitchen). Returns true when they're on it.
    func apply(model: AppModel, router: AppRouter) async -> Bool {
        guard let preview else { return false }
        phase = .applying
        do {
            for row in preview.rows where row.change != .keeps {
                let day = PlanDates.day(forISO: row.isoDate)
                let week = ISODay.weekStart(containing: ISODay.date(from: row.isoDate) ?? .now)
                var update = PlanSlotUpdate(weekStart: week, day: day, slot: row.slot)
                if let found = preview.lookup[row.title.lowercased()] {
                    update.recipeItems = [PlannerMealItem(
                        title: row.title, role: .entree, imageUrl: found.imageUrl, recipeId: found.recipeId,
                        recipeVersionId: nil, source: "library", recipeStatus: nil, currentVersionId: nil, hasUpdateAvailable: nil
                    )]
                    update.customMeal = .some(nil)
                } else {
                    update.recipeItems = []
                    update.customMeal = .some(row.title)
                }
                update.dineOut = .some(nil)
                update.completed = false
                _ = try await KitchenStore.shared.updateSlot(update)
            }
            let plans = PlanStore.shared
            for week in previewWeeks(of: preview) {
                plans.invalidate(week)
                await plans.load(week, force: true)
            }
            if !previewWeeks(of: preview).contains(router.weekStart) {
                await plans.load(router.weekStart, force: true)
            }
            phase = .idle
            self.preview = nil
            return true
        } catch {
            phase = .idle
            handle(error, router: router)
            return false
        }
    }

    func discardPreview() {
        preview = nil
    }

    private func previewWeeks(of preview: AIPlanPreview) -> [String] {
        var seen = Set<String>()
        return preview.dates.compactMap { iso in
            let week = ISODay.weekStart(containing: ISODay.date(from: iso) ?? .now)
            return seen.insert(week).inserted ? week : nil
        }
    }

    private func handle(_ error: Error, router: AppRouter) {
        if error is CancellationError { return }
        if let apiError = error as? APIError, apiError.isLimitReached || apiError.code == "LIMIT_REACHED" {
            router.present(.paywall)
            return
        }
        self.error = error.localizedDescription
    }

    /// Lines up each chosen day and meal with what's planned now and what the AI picked.
    private func makeRows(request: MealPlanRequest, plan: [String: [String: String]], lookup: [String: MealPlanResponse.LookupEntry]) -> [AIPlanPreviewRow] {
        var rows: [AIPlanPreviewRow] = []
        for iso in (request.selectedDates ?? []).sorted() {
            let day = PlanDates.day(forISO: iso)
            let week = ISODay.weekStart(containing: ISODay.date(from: iso) ?? .now)
            let baseline = PlanStore.shared.planner(week)
            for slotName in request.selectedMeals?[day.rawValue] ?? [] {
                guard let slot = MealSlotType(rawValue: slotName) else { continue }
                let generated = plan[day.rawValue]?[slot.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let previous = baseline.flatMap { PlanSlotText.primaryTitle($0.slot(day, slot)) }
                // With "replace" off, a planned meal wasn't sent and stays.
                let kept = !(request.overwriteExisting ?? true) ? previous : nil
                guard let title = kept ?? generated, !title.isEmpty else { continue }
                let image = kept == nil ? lookup[title.lowercased()]?.imageUrl : baseline.flatMap { PlanSlotText.primaryImage($0.slot(day, slot)) }

                let change: AIPlanPreviewRow.Change
                if let previous {
                    if !(request.overwriteExisting ?? true) {
                        change = .keeps
                    } else if previous.caseInsensitiveCompare(title) == .orderedSame {
                        change = .same
                    } else {
                        change = .replaces
                    }
                } else {
                    change = .new
                }
                rows.append(AIPlanPreviewRow(
                    isoDate: iso,
                    slot: slot,
                    title: change == .keeps ? previous ?? title : title,
                    previousTitle: change == .replaces ? previous : nil,
                    imageUrl: image,
                    change: change
                ))
            }
        }
        return rows
    }
}
