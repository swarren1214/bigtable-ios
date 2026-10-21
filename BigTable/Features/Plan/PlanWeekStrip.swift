import Foundation
import SwiftUI

/// The week at the top of Plan: the date range with previous/next week, Today, and a day per
/// column. A full dot under a day means all three meals are planned; a faint one means some
/// are. Swipe sideways to change weeks.
struct PlanWeekStrip: View {
    var weekStart: String
    @Binding var selectedDay: DayOfWeek
    var planner: PlannerResponse?
    /// -1 for the previous week, +1 for the next.
    var onShiftWeek: (Int) -> Void
    var onToday: () -> Void

    @Environment(\.accent) private var accent
    @State private var direction = 1

    private var isCurrentWeek: Bool { weekStart == PlanDates.currentWeekStart }

    private var caption: String? {
        let current = PlanDates.currentWeekStart
        if weekStart == current { return "This week" }
        if weekStart == ISODay.adding(days: 7, to: current) { return "Next week" }
        if weekStart == ISODay.adding(days: -7, to: current) { return "Last week" }
        return nil
    }

    var body: some View {
        Card(padding: 12) {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Button { shift(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Previous week")

                    Spacer(minLength: 0)

                    VStack(spacing: 1) {
                        Text(PlanDates.rangeLabel(weekStart: weekStart))
                            .font(.headline)
                            .contentTransition(.numericText())
                        HStack(spacing: 6) {
                            if let caption {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !isCurrentWeek {
                                Button("Today", action: today)
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Go to this week")
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    Button { shift(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Next week")
                }
                .tint(.primary)

                HStack(spacing: 2) {
                    ForEach(DayOfWeek.allCases) { day in
                        dayButton(day)
                    }
                }
                .id(weekStart)
                .transition(.push(from: direction > 0 ? .trailing : .leading))
            }
            .clipped()
        }
        .contentShape(.rect)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let dx = value.translation.width
                    guard abs(dx) > 50, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                    shift(dx < 0 ? 1 : -1)
                }
        )
    }

    private func shift(_ delta: Int) {
        direction = delta
        withAnimation(.snappy) { onShiftWeek(delta) }
    }

    private func today() {
        direction = PlanDates.currentWeekStart >= weekStart ? 1 : -1
        withAnimation(.snappy) { onToday() }
    }

    private func plannedCount(_ day: DayOfWeek) -> Int {
        guard let planner else { return 0 }
        return MealSlotType.allCases.filter { !planner.slot(day, $0).isEmpty }.count
    }

    private func dayButton(_ day: DayOfWeek) -> some View {
        let iso = PlanDates.iso(weekStart: weekStart, day: day)
        let isToday = iso == PlanDates.todayISO
        let isSelected = day == selectedDay
        let planned = plannedCount(day)
        let full = planned == MealSlotType.allCases.count

        return Button {
            withAnimation(.snappy) { selectedDay = day }
        } label: {
            VStack(spacing: 4) {
                Text(day.short.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                Text(PlanDates.dayNumber(weekStart: weekStart, day: day))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : (isToday ? AnyShapeStyle(accent) : AnyShapeStyle(.primary)))
                    .frame(width: 36, height: 36)
                    .background {
                        if isSelected {
                            Circle().fill(accent)
                        } else if isToday {
                            Circle().strokeBorder(accent, lineWidth: 1.5)
                        }
                    }
                Circle()
                    .fill(full ? accent : Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
                    .opacity(planned == 0 ? 0 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(iso: iso, planned: planned, isToday: isToday))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityLabel(iso: String, planned: Int, isToday: Bool) -> String {
        let date = ISODay.date(from: iso)?.formatted(.dateTime.weekday(.wide).month(.wide).day()) ?? iso
        let meals = planned == 0 ? "nothing planned" : "\(planned) of 3 meals planned"
        return isToday ? "Today, \(date), \(meals)" : "\(date), \(meals)"
    }
}
