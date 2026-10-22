import Foundation
import SwiftUI

// iPhone Duo, Open wide (the inner display in landscape): "Plan the week". Recipes on the
// leading pane, the week on the trailing pane; drag a recipe onto an empty night. PlanView
// switches to this arrangement from the pose (`\.hearthDuoPose`); everything here uses the
// same stores as the rest of Plan, so nothing is lost when the phone turns or closes.

/// The leading pane: the recipe library with its search and quick filters above it (next to
/// what they affect). Each recipe can be dragged onto a night, or added from its context menu
/// (the way to do it without dragging, and for VoiceOver).
struct PlanRecipeShelf: View {
    @Bindable var store: RecipeStore
    var weekStart: String
    var canPlan: Bool
    var onAdd: (RecipeSummary, DayOfWeek) -> Void

    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderTitle("Recipes")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search recipes", text: $store.query)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                    if !store.query.isEmpty {
                        Button {
                            store.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())

                Picker("Recipes", selection: $store.collection) {
                    ForEach(RecipeCollection.allCases) { collection in
                        Text(collection.label).tag(collection)
                    }
                }
                .pickerStyle(.segmented)

                RecipeQuickFilterBar(selection: $store.quickFilter)

                results
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: store.collection) { Task { await store.reload() } }
        .onChange(of: store.quickFilter) { Task { await store.reload() } }
        .onChange(of: store.query) { store.queryChanged() }
        .onChange(of: KitchenStore.shared.revision) { Task { await store.reload() } }
        .task { await store.loadIfNeeded() }
    }

    @ViewBuilder
    private var results: some View {
        if store.recipes.isEmpty {
            if store.isLoading || !store.hasLoaded && store.loadError == nil {
                LoadingCard(title: "Loading recipes…")
            } else if let error = store.loadError {
                RetryCard(message: error) { Task { await store.reload() } }
            } else {
                EmptyCard(symbol: "magnifyingglass", title: "No recipes found", message: "Try another search or filter.")
            }
        } else {
            LazyVStack(spacing: 8) {
                ForEach(store.recipes) { recipe in
                    row(recipe)
                        .onAppear { store.loadMoreIfNeeded(after: recipe) }
                }
                if store.isLoadingMore {
                    ProgressView()
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func row(_ recipe: RecipeSummary) -> some View {
        Button {
            router.present(.recipe(id: recipe.id, versionID: nil))
        } label: {
            RecipeRow(recipe: recipe) {
                if canPlan {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .draggable(recipe.id)
        .contextMenu {
            if canPlan {
                ForEach(openDays) { day in
                    Button("Add to \(day.label) Dinner", menuIcon: "calendar.badge.plus") {
                        onAdd(recipe, day)
                    }
                }
            }
        }
        .accessibilityHint(canPlan ? "Opens the recipe. Drag it onto a night, or use the actions menu, to plan it." : "Opens the recipe")
    }

    /// Days of the week on screen that haven't passed.
    private var openDays: [DayOfWeek] {
        DayOfWeek.allCases.filter { PlanDates.iso(weekStart: weekStart, day: $0) >= PlanDates.todayISO }
    }
}

/// The week's nights at a glance, for the trailing pane: each day's dinner, and on an empty
/// night that hasn't passed, a place to drop a recipe. Tap a night to see that day below.
struct PlanNightsCard: View {
    var weekStart: String
    var planner: PlannerResponse
    var canManage: Bool
    @Binding var selectedDay: DayOfWeek
    /// Off where the nights are only for reading (beside the grocery list).
    var isSelectable = true
    /// The recipe dropped on a night, by id.
    var onDrop: (String, DayOfWeek) -> Bool = { _, _ in false }

    @Environment(\.accent) private var accent
    @State private var target: DayOfWeek?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Dinners")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(DayOfWeek.allCases) { day in
                        night(day)
                        if day != DayOfWeek.allCases.last {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
            }
        }
    }

    private func canDrop(_ day: DayOfWeek) -> Bool {
        canManage
            && planner.slot(day, .dinner).isEmpty
            && PlanDates.iso(weekStart: weekStart, day: day) >= PlanDates.todayISO
    }

    private func night(_ day: DayOfWeek) -> some View {
        let slot = planner.slot(day, .dinner)
        let open = canDrop(day)
        let isTarget = target == day
        let isSelected = isSelectable && selectedDay == day
        let traits: AccessibilityTraits = !isSelectable ? [] : (isSelected ? [.isButton, .isSelected] : [.isButton])
        return HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(day.short.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(PlanDates.dayNumber(weekStart: weekStart, day: day))
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 40)

            if let title = PlanSlotText.primaryTitle(slot) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            } else {
                Text(open ? (isTarget ? "Drop to plan dinner" : "Drag a recipe here") : "Nothing planned")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if slot.completed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(MealSlotType.dinner.color)
                    .accessibilityLabel("Cooked")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .background {
            if isTarget {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(accent.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
                    .padding(4)
            } else if isSelected {
                Color(.tertiarySystemFill)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard isSelectable else { return }
            withAnimation(.snappy) { selectedDay = day }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard open, let id = ids.first else { return false }
            return onDrop(id, day)
        } isTargeted: { targeted in
            if targeted, open {
                target = day
            } else if target == day {
                target = nil
            }
        }
        .animation(.snappy, value: isTarget)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(traits)
        .accessibilityHint(isSelectable ? "Shows this day's meals" : "")
    }
}

/// The week beside the grocery list (iPhone Duo open wide): this week's dinners, so the list
/// can be checked against what's planned. Read-only; the Plan tab changes it.
struct GroceryWeekPane: View {
    @Environment(AppRouter.self) private var router
    @State private var store = PlanStore.shared
    @State private var day: DayOfWeek = PlanDates.day(for: .now)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderTitle("This Week", subtitle: PlanDates.rangeLabel(weekStart: router.weekStart))
                if let planner = store.planner(router.weekStart) {
                    PlanNightsCard(
                        weekStart: router.weekStart,
                        planner: planner,
                        canManage: false,
                        selectedDay: $day,
                        isSelectable: false
                    )
                } else if let error = store.loadErrors[router.weekStart] {
                    RetryCard(message: error) {
                        Task { await store.load(router.weekStart, force: true) }
                    }
                } else {
                    LoadingCard(title: "Loading the plan…")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .refreshable { await store.load(router.weekStart, force: true) }
        .task(id: router.weekStart) { await store.load(router.weekStart) }
    }
}
