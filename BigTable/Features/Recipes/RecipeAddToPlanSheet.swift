import Foundation
import SwiftUI

/// Add to Plan: pick a day (this week or another), breakfast, lunch or dinner, and whether it's
/// the main dish, a side or dessert. If that meal already has something planned, you choose to
/// add this alongside it or replace it.
struct RecipeAddToPlanSheet: View {
    let recipe: RecipeDetail

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent

    @State private var weekStart: String
    @State private var day: DayOfWeek
    @State private var slot: MealSlotType = .dinner
    @State private var role: PlannerMealRole = .entree
    @State private var plan: PlannerResponse?
    @State private var isLoadingPlan = false
    @State private var planError: String?
    @State private var isSaving = false
    @State private var askReplace = false
    @State private var errorMessage: String?
    @State private var duplicateNotice: String?
    @State private var savedCount = 0

    private let api = BigTableAPI.shared

    init(recipe: RecipeDetail) {
        self.recipe = recipe
        let thisWeek = ISODay.weekStart(containing: .now)
        let planWeek = AppRouter.shared.weekStart
        // Start on the week the Plan tab shows, unless it's already in the past.
        let start = planWeek >= thisWeek ? planWeek : thisWeek
        _weekStart = State(initialValue: start)
        let today = ISODay.string(from: .now)
        let todayOffset = (0..<7).first { ISODay.adding(days: $0, to: start) == today } ?? 0
        _day = State(initialValue: DayOfWeek.allCases[todayOffset])
    }

    private var today: String { ISODay.string(from: .now) }
    private var thisWeek: String { ISODay.weekStart(containing: .now) }

    private var currentSlot: PlannerSlot? {
        guard let plan, plan.weekStart == weekStart else { return nil }
        return plan.slot(day, slot)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        RecipePhoto(url: recipe.imageUrl, cornerRadius: 10, symbolSize: 16)
                            .frame(width: 44, height: 44)
                        Text(recipe.title)
                            .font(.headline)
                            .lineLimit(2)
                    }
                }

                Section {
                    weekHeader
                    dayStrip
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 12, trailing: 8))
                } header: {
                    Text("Day")
                }

                Section {
                    Picker("Meal", selection: $slot) {
                        ForEach(MealSlotType.allCases) { slot in
                            Text(slot.label).tag(slot)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Meal")
                }

                Section {
                    Picker("Course", selection: $role) {
                        ForEach(PlannerMealRole.allCases) { role in
                            Text(role.label).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Course")
                }

                Section {
                    plannedSummary
                } footer: {
                    if let planError {
                        Text(planError)
                    }
                }
            }
            .navigationTitle("Add to Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Add", systemImage: "checkmark") { requestAdd() }
                            .disabled(isLoadingPlan || isPast(day))
                    }
                }
            }
            .task(id: weekStart) { await loadPlan() }
            .alert("Meal already planned", isPresented: $askReplace) {
                Button("Add Alongside") { Task { await add(replacing: false) } }
                Button("Replace", role: .destructive) { Task { await add(replacing: true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(day.label) \(slot.label.lowercased()) already has \(currentSlot?.title ?? "a meal"). Add this recipe alongside it, or replace it?")
            }
            .alert("Already planned", isPresented: Binding(get: { duplicateNotice != nil }, set: { if !$0 { duplicateNotice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(duplicateNotice ?? "")
            }
            .errorAlert($errorMessage, title: "Couldn't add to the plan")
            .sensoryFeedback(.success, trigger: savedCount)
        }
        .presentationDetents([.large])
    }

    // MARK: Pieces

    private var weekHeader: some View {
        HStack {
            Button {
                weekStart = ISODay.adding(days: -7, to: weekStart)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(weekStart <= thisWeek)
            .accessibilityLabel("Previous week")

            Spacer()
            Text(weekLabel)
                .font(.headline)
            Spacer()

            Button {
                weekStart = ISODay.adding(days: 7, to: weekStart)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Next week")
        }
    }

    private var dayStrip: some View {
        HStack(spacing: 4) {
            ForEach(DayOfWeek.allCases) { option in
                let iso = ISODay.adding(days: option.offset, to: weekStart)
                let isSelected = option == day
                let past = iso < today
                Button {
                    day = option
                } label: {
                    VStack(spacing: 4) {
                        Text(option.short)
                            .font(.caption2.weight(.semibold))
                        Text(dayNumber(iso))
                            .font(.headline)
                        Circle()
                            .fill(hasMeals(option) ? (isSelected ? Color.white : accent) : Color.clear)
                            .frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .foregroundStyle(isSelected ? Color.white : (past ? Color.secondary : Color.primary))
                    .background(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 14, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(past)
                .accessibilityLabel("\(option.label) \(dayNumber(iso))\(hasMeals(option) ? ", has meals planned" : "")")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var plannedSummary: some View {
        if isLoadingPlan, plan?.weekStart != weekStart {
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking the plan…").foregroundStyle(.secondary)
            }
        } else if let current = currentSlot, !current.isEmpty {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Already planned").font(.subheadline.weight(.semibold))
                    Text(current.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: slot.symbol)
                    .foregroundStyle(slot.color)
            }
        } else {
            Label {
                Text("\(day.label) \(slot.label.lowercased()) is open.")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: slot.symbol)
                    .foregroundStyle(slot.color)
            }
        }
    }

    // MARK: Helpers

    private var weekLabel: String {
        guard let start = ISODay.date(from: weekStart),
              let end = Calendar.current.date(byAdding: .day, value: 6, to: start) else { return weekStart }
        if weekStart == thisWeek { return "This week" }
        if weekStart == ISODay.adding(days: 7, to: thisWeek) { return "Next week" }
        let startText = start.formatted(.dateTime.month(.abbreviated).day())
        let endText = Calendar.current.isDate(start, equalTo: end, toGranularity: .month)
            ? end.formatted(.dateTime.day())
            : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startText) – \(endText)"
    }

    private func dayNumber(_ iso: String) -> String {
        guard let date = ISODay.date(from: iso) else { return "" }
        return date.formatted(.dateTime.day())
    }

    private func isPast(_ option: DayOfWeek) -> Bool {
        ISODay.adding(days: option.offset, to: weekStart) < today
    }

    private func hasMeals(_ option: DayOfWeek) -> Bool {
        guard let plan, plan.weekStart == weekStart else { return false }
        return MealSlotType.allCases.contains { !plan.slot(option, $0).isEmpty }
    }

    // MARK: Loading and saving

    private func loadPlan() async {
        isLoadingPlan = true
        planError = nil
        do {
            let loaded = try await api.currentPlan(weekStart: weekStart)
            if loaded.weekStart == weekStart || plan == nil {
                plan = loaded
            }
        } catch is CancellationError {
            return
        } catch {
            planError = "Couldn't check what's planned: \(error.localizedDescription)"
        }
        isLoadingPlan = false
        if isPast(day), let firstOpen = DayOfWeek.allCases.first(where: { !isPast($0) }) {
            day = firstOpen
        }
    }

    private func requestAdd() {
        guard let current = currentSlot else {
            Task { await add(replacing: false) }
            return
        }
        let duplicate = current.recipeItems.contains { item in
            (item.recipeId != nil && item.recipeId == recipe.id)
                || item.title.recipeTrimmed.lowercased() == recipe.title.recipeTrimmed.lowercased()
        }
        if duplicate {
            duplicateNotice = "\(recipe.title) is already in \(day.label) \(slot.label.lowercased())."
            return
        }
        if current.isEmpty {
            Task { await add(replacing: false) }
        } else {
            askReplace = true
        }
    }

    /// Adds the recipe to the slot as the Expo app did: pinned to the recipe's current version
    /// (a custom meal when it has none yet), and the slot's first title as its custom meal.
    private func add(replacing: Bool) async {
        isSaving = true
        defer { isSaving = false }
        do {
            if plan?.weekStart != weekStart {
                plan = try await api.currentPlan(weekStart: weekStart)
            }
            let current = plan?.slot(day, slot) ?? PlannerSlot()
            let versionID = recipe.currentVersionId?.recipeTrimmed
            let pinned = (versionID?.isEmpty == false) ? versionID : nil
            let item = PlannerMealItem(
                title: recipe.title,
                role: role,
                imageUrl: recipe.imageUrl,
                recipeId: pinned == nil ? nil : recipe.id,
                recipeVersionId: pinned,
                source: pinned == nil ? "custom" : "library"
            )
            let items = replacing ? [item] : current.recipeItems + [item]
            var update = PlanSlotUpdate(weekStart: weekStart, day: day, slot: slot)
            let firstTitle: String = items.first?.title ?? recipe.title
            update.customMeal = firstTitle
            update.dineOut = .some(nil)
            update.recipeItems = items
            update.excludedMembers = current.excludedMembers
            update.completed = false
            let response = try await api.updateSlot(update)
            plan?.set(response.slotData, day: day, slot: slot)
            // The Plan tab caches weeks; make it show this right away.
            await PlanStore.shared.load(weekStart, force: true)
            savedCount += 1
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
