import Combine
import SwiftUI

/// Breakfast, lunch and dinner times, shared between BigTable and Caloma: change them in
/// either app and the other follows (`HearthMealTimes`).
struct MealTimesView: View {
    /// The app saving the change.
    var app: HearthApp
    @State private var times = HearthMealTimes.current

    var body: some View {
        Form {
            Section {
                picker("Breakfast", \.breakfast, symbol: "sunrise.fill")
                picker("Lunch", \.lunch, symbol: "sun.max.fill")
                picker("Dinner", \.dinner, symbol: "moon.stars.fill")
            } footer: {
                Text("BigTable and Caloma share these, so change them in either app. Caloma shows planned meals on the calendar at these times.")
            }
            if times != .standard {
                Section {
                    Button("Reset to 8 AM, Noon and 6 PM") { times = .standard }
                }
            }
        }
        .navigationTitle("Meal Times")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: times) { _, new in
            _ = Hearth.publish(new, from: app)
        }
        // Changed in the other app while this screen is open.
        .onReceive(NotificationCenter.default.publisher(for: Hearth.didChange)) { _ in
            let latest = HearthMealTimes.current
            if latest != times { times = latest }
        }
    }

    private func picker(_ title: String, _ key: WritableKeyPath<HearthMealTimes, Int>, symbol: String) -> some View {
        DatePicker(selection: Binding(
            get: { Self.date(minutes: times[keyPath: key]) },
            set: { times[keyPath: key] = Self.minutes(of: $0) }
        ), displayedComponents: .hourAndMinute) {
            Label(title, systemImage: symbol)
        }
    }

    private static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }

    private static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

extension HearthMealTimes {
    /// "8 AM · 12 PM · 6 PM", for a settings row.
    var summary: String {
        [breakfast, lunch, dinner].map { minutes in
            let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
            return minutes % 60 == 0 ? date.formatted(.dateTime.hour()) : date.formatted(date: .omitted, time: .shortened)
        }
        .joined(separator: " · ")
    }
}
