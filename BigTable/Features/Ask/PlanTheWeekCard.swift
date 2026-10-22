import SwiftUI

/// The top of BigTable AI (the ✨ sheet): the AI meal planner, with how much of this week is
/// still open. Plan with AI opens the planner inside the same sheet.
struct PlanTheWeekCard: View {
    var onPlan: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconTile(symbol: "calendar.badge.plus", color: accent, size: 48, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan the Week")
                        .font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(PlanOpenMeals.summary())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: onPlan) {
                Label("Plan with AI", systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(accent)
            if let usageText {
                Text(usageText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskStyle.cardBackground, in: .rect(cornerRadius: 24, style: .continuous))
    }

    /// The plan's allowance, as the planner shows it.
    private var usageText: String? {
        guard model.hasPro else { return "Part of BigTable Plus" }
        guard let usage = model.usage else { return nil }
        if !usage.canMakeRequest { return "You've used this month's AI plans" }
        return "\(usage.requestsUsed) of \(usage.requestsLimit) AI credits used this month"
    }
}

/// After Ask puts a meal on the plan: the rest of the week's open meals, in one go.
struct PlanHandOffCard: View {
    var onPlan: () -> Void

    var body: some View {
        let open = PlanOpenMeals.current()
        VStack(alignment: .leading, spacing: 10) {
            Text(open.count == 0 ? "Want to plan next week too?" : "\(PlanOpenMeals.summary()), too.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onPlan) {
                Label(open.count == 0 ? "Plan Next Week" : "Plan the Rest of the Week", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(.systemBackground))
            .background(Color.primary, in: .capsule)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(.separator)))
    }
}

/// The meals not planned yet from today to the end of this week.
enum PlanOpenMeals {
    static func current() -> (count: Int, days: [DayOfWeek]) {
        let weekStart = ISODay.weekStart(containing: .now)
        guard let planner = PlanStore.shared.planner(weekStart) else { return (0, []) }
        let end = ISODay.adding(days: 6, to: weekStart)
        var count = 0
        var days: [DayOfWeek] = []
        for iso in PlanDates.dates(from: PlanDates.todayISO, to: end) {
            let day = PlanDates.day(forISO: iso)
            let empty = MealSlotType.allCases.filter { planner.slot(day, $0).isEmpty }.count
            if empty > 0 {
                count += empty
                days.append(day)
            }
        }
        return (count, days)
    }

    /// "Thu–Sat have 6 empty meals", "Saturday has 1 empty meal", "This week is all planned".
    static func summary() -> String {
        let open = current()
        guard open.count > 0, let first = open.days.first, let last = open.days.last else {
            return "This week is all planned"
        }
        let meals = open.count == 1 ? "1 empty meal" : "\(open.count) empty meals"
        if first == last { return "\(first.label) has \(meals)" }
        return "\(first.short)–\(last.short) have \(meals)"
    }
}
