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
    /// The request that made it; sent again with `previewOnly: false` to save it.
    var request: MealPlanRequest
    var generatedPlan: [String: [String: String]]
    var generatedBy: String
    var rows: [AIPlanPreviewRow]

    var dates: [String] {
        var seen = Set<String>()
        return rows.map(\.isoDate).filter { seen.insert($0).inserted }
    }
}

/// Everything the AI meal planner sheet holds: the person's choices, the request in flight,
/// and the preview. Generating asks for a preview first (`previewOnly`); adding sends the
/// same request back with the previewed plan so exactly that plan is saved.
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
            generatedBy: nil
        )
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
        phase = .requesting
        // The request takes a while; move the progress along so it doesn't look stuck.
        let stepper = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.phase == .requesting else { return }
            self.phase = .drafting
        }
        defer { stepper.cancel() }

        do {
            let response = try await api.generateMealPlan(request)
            phase = .drafting
            model.updateUsage(response.usage)
            guard let plan = response.generatedPlan else {
                phase = .idle
                error = "The planner didn't send back any meals. Try again."
                return false
            }
            preview = AIPlanPreview(
                request: request,
                generatedPlan: plan,
                generatedBy: response.generatedBy,
                rows: makeRows(request: request, plan: plan, previewPlanner: response.previewPlanner)
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

    /// Saves the previewed plan. Returns true when it's on the plan.
    func apply(model: AppModel, router: AppRouter) async -> Bool {
        guard let preview else { return false }
        var request = preview.request
        request.previewOnly = false
        request.generatedPlan = preview.generatedPlan
        request.generatedBy = preview.generatedBy
        phase = .applying
        do {
            let response = try await api.generateMealPlan(request)
            model.updateUsage(response.usage)
            let plans = PlanStore.shared
            if let planner = response.planner {
                plans.replace(planner)
            }
            // The range can reach into a second week; reload any the response didn't cover.
            for week in previewWeeks(of: preview) where week != response.planner?.weekStart {
                plans.invalidate(week)
                await plans.load(week, force: true)
            }
            if response.planner?.weekStart != router.weekStart {
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
    private func makeRows(request: MealPlanRequest, plan: [String: [String: String]], previewPlanner: PlannerResponse?) -> [AIPlanPreviewRow] {
        var rows: [AIPlanPreviewRow] = []
        for iso in (request.selectedDates ?? []).sorted() {
            let day = PlanDates.day(forISO: iso)
            let week = ISODay.weekStart(containing: ISODay.date(from: iso) ?? .now)
            let baseline = PlanStore.shared.planner(week)
            let previewForWeek = previewPlanner?.weekStart == week ? previewPlanner : nil
            for slotName in request.selectedMeals?[day.rawValue] ?? [] {
                guard let slot = MealSlotType(rawValue: slotName) else { continue }
                let generated = plan[day.rawValue]?[slot.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let previous = baseline.flatMap { PlanSlotText.primaryTitle($0.slot(day, slot)) }
                let previewSlot = previewForWeek?.slot(day, slot)
                let shown = previewSlot.flatMap { PlanSlotText.primaryTitle($0) } ?? generated
                guard let title = shown, !title.isEmpty else { continue }
                let image = previewSlot.flatMap { PlanSlotText.primaryImage($0) }

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
