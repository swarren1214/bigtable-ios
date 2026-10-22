import SwiftUI

/// The next meal: what it is, when, how many it feeds and how long it takes, with Start Cooking;
/// then what's after it. A running timer sits on top.
struct TonightView: View {
    @Environment(WatchStore.self) private var store
    @Environment(CookTimer.self) private var timer

    var body: some View {
        let snapshot = store.snapshot
        let meal = snapshot.nextMeal()
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if timer.isActive {
                    NavigationLink {
                        TimerView()
                    } label: {
                        TimerChip()
                    }
                    .buttonStyle(.plain)
                }
                if let meal {
                    MealCard(meal: meal)
                    let later = snapshot.meals(after: meal)
                    if !later.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(later.first?.isToday == true ? "Later" : "Tomorrow")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            ForEach(later) { next in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(next.title)
                                        .font(.body.weight(.semibold))
                                        .lineLimit(2)
                                    Spacer(minLength: 4)
                                    Text(next.slotLabel)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    }
                } else if store.hasData {
                    VStack(spacing: 6) {
                        Image(systemName: "fork.knife")
                            .font(.title2)
                            .accessibilityHidden(true)
                        Text("Nothing planned")
                            .font(.headline)
                        Text("Plan meals in BigTable on your iPhone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    WaitingForPhone()
                }
            }
        }
        .navigationTitle(title(for: meal))
        .bigTablePage()
    }

    private func title(for meal: WatchMeal?) -> String {
        guard let meal else { return "BigTable" }
        if !meal.isToday { return "Tomorrow" }
        return meal.slot == "dinner" ? "Tonight" : "Today"
    }
}

/// The next meal's card.
private struct MealCard: View {
    let meal: WatchMeal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(meal.slotLabel) · \(meal.startsAt.formatted(date: .omitted, time: .shortened))")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(meal.title)
                .font(.title3.weight(.bold))
                .lineLimit(3)
            HStack(spacing: 10) {
                if let servings = meal.servings {
                    Label("Serves \(servings)", systemImage: "person.2")
                }
                if let minutes = meal.minutes {
                    Label("\(minutes) min", systemImage: "clock")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .labelStyle(CompactLabel())

            let recipes = meal.cookable
            if recipes.count == 1, let recipe = recipes.first {
                NavigationLink {
                    CookView(recipe: recipe)
                } label: {
                    Label("Start Cooking", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            } else if recipes.count > 1 {
                NavigationLink {
                    RecipeChooser(meal: meal)
                } label: {
                    Label("Start Cooking", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            } else if meal.isToday, let start = meal.startCookingAt, start > .now {
                Text("Start by \(start.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 20, style: .continuous))
    }
}

/// A meal of more than one recipe ("Fajitas + Rice"): which to cook from.
private struct RecipeChooser: View {
    let meal: WatchMeal

    var body: some View {
        List(meal.cookable) { recipe in
            NavigationLink {
                CookView(recipe: recipe)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.title)
                        .font(.headline)
                    Text("\(recipe.steps.count) steps")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Cook")
    }
}

/// Icon and text close together, for the small details under a title.
struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// The running timer, at the top of Tonight.
struct TimerChip: View {
    @Environment(CookTimer.self) private var timer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: timer.isPaused ? "pause.circle.fill" : "timer")
                .font(.title3)
                .foregroundStyle(WatchTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(timer.label)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if let end = timer.endsAt {
                    Text(timerInterval: Date.now...max(end, .now), countsDown: true)
                        .font(.title3.monospacedDigit().weight(.semibold))
                } else {
                    Text(Duration.seconds(timer.remaining()).formatted(.time(pattern: .minuteSecond)))
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the timer")
    }
}
