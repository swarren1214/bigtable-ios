import SwiftUI
import WidgetKit

// BigTable's complications on the watch face and in the Smart Stack: the next meal (and a
// running cooking timer), what's left on the grocery list, and a button for Tell the Pantry.
// They read what the watch app saved from the iPhone (WatchShared).

@main
struct BigTableWidgets: WidgetBundle {
    var body: some Widget {
        NextMealWidget()
        GroceryWidget()
        PantryWidget()
    }
}

private let accent = Color(red: 0xD9 / 255, green: 0x47 / 255, blue: 0x2B / 255)

// MARK: - Timeline

struct BigTableEntry: TimelineEntry {
    var date: Date
    var meal: WatchMeal?
    var grocery: WatchGrocery?
    var timerEnd: Date?
    var timerLabel: String?
}

struct BigTableProvider: TimelineProvider {
    func placeholder(in context: Context) -> BigTableEntry {
        BigTableEntry(
            date: .now,
            meal: WatchMeal(id: "sample", slot: "dinner", startsAt: Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: .now) ?? .now,
                            title: "Chickpea Fajitas", servings: 6, minutes: 25, recipes: [], completed: false),
            grocery: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BigTableEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entries().first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BigTableEntry>) -> Void) {
        let entries = entries()
        // The app reloads these whenever the phone sends something new; otherwise look again in
        // a few hours (a new day).
        completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(4 * 3600))))
    }

    /// One entry now, then one each time a meal passes and the next one takes over.
    private func entries() -> [BigTableEntry] {
        let snapshot = WatchShared.loadSnapshot() ?? .empty
        let defaults = WatchShared.defaults
        var timerEnd = defaults.object(forKey: WatchShared.timerEndKey) as? Date
        if let end = timerEnd, end <= .now { timerEnd = nil }
        let timerLabel = defaults.string(forKey: WatchShared.timerLabelKey)

        var dates: [Date] = [.now]
        for meal in snapshot.meals {
            let over = meal.startsAt.addingTimeInterval(2 * 3600)
            if over > .now { dates.append(over) }
        }
        if let timerEnd { dates.append(timerEnd) }
        return dates.sorted().map { date in
            BigTableEntry(
                date: date,
                meal: snapshot.nextMeal(now: date),
                grocery: snapshot.grocery,
                timerEnd: timerEnd.flatMap { $0 > date ? $0 : nil },
                timerLabel: timerLabel
            )
        }
    }
}

// MARK: - Next meal

struct NextMealWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextMeal", provider: BigTableProvider()) { entry in
            NextMealView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "bigtable-watch://tonight"))
        }
        .configurationDisplayName("Next Meal")
        .description("What's for dinner, when, and when to start cooking.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

struct NextMealView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BigTableEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            if let end = entry.timerEnd {
                Text("\(entry.timerLabel ?? "Timer") \(Text(timerInterval: entry.date...end, countsDown: true))")
            } else if let meal = entry.meal {
                Text("\(meal.title) · \(meal.startsAt.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Nothing planned")
            }
        default:
            rectangular
        }
    }

    @ViewBuilder
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let end = entry.timerEnd {
                Label(entry.timerLabel ?? "Timer", systemImage: "timer")
                    .font(.headline)
                    .foregroundStyle(accent)
                    .widgetAccentable()
                Text(timerInterval: entry.date...end, countsDown: true)
                    .font(.title2.monospacedDigit().weight(.semibold))
                if let meal = entry.meal {
                    Text(meal.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if let meal = entry.meal {
                Text("\(meal.slotLabel) · \(meal.startsAt.formatted(date: .omitted, time: .shortened))")
                    .font(.headline)
                    .foregroundStyle(accent)
                    .widgetAccentable()
                Text(meal.title)
                    .font(.headline)
                    .lineLimit(2)
                if meal.isToday, let start = meal.startCookingAt, start > entry.date {
                    Text("Start by \(start.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !meal.isToday {
                    Text("Tomorrow")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("BigTable")
                    .font(.headline)
                    .foregroundStyle(accent)
                    .widgetAccentable()
                Text("Nothing planned")
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Grocery

struct GroceryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Grocery", provider: BigTableProvider()) { entry in
            GroceryComplication(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "bigtable-watch://grocery"))
        }
        .configurationDisplayName("Grocery List")
        .description("How much is left to buy.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

struct GroceryComplication: View {
    @Environment(\.widgetFamily) private var family
    let entry: BigTableEntry

    var body: some View {
        let total = entry.grocery?.total ?? 0
        let left = entry.grocery?.remaining ?? 0
        let bought = Double(total - left)
        switch family {
        case .accessoryCorner:
            Image(systemName: "cart")
                .font(.title3)
                .widgetLabel {
                    Gauge(value: bought, in: 0...Double(max(total, 1))) {
                        Text("Grocery")
                    } currentValueLabel: {
                        Text("\(left)")
                    }
                    .tint(accent)
                }
                .accessibilityLabel("\(left) left to buy")
        default:
            Gauge(value: bought, in: 0...Double(max(total, 1))) {
                Image(systemName: "cart")
            } currentValueLabel: {
                Text("\(left)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(accent)
            .accessibilityLabel(total == 0 ? "No grocery list" : "\(left) left to buy")
        }
    }
}

// MARK: - Tell the Pantry

struct PantryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TellThePantry", provider: BigTableProvider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .widgetAccentable()
            }
            .accessibilityLabel("Tell the Pantry")
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(URL(string: "bigtable-watch://pantry"))
        }
        .configurationDisplayName("Tell the Pantry")
        .description("Say what you bought or what you're out of.")
        .supportedFamilies([.accessoryCircular])
    }
}
