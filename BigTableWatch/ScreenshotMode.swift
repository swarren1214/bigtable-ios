import Foundation

/// Screenshot mode, for marketing screenshots of the Watch app.
///
/// Launched with `-Screenshots`, the Watch app shows a demo `WatchSnapshot` kept in memory instead
/// of the phone's: tonight's dinner (the iPhone demo's Sheet-Pan Chicken Fajitas), what's planned
/// after it, and a grocery list part checked off. It doesn't activate WatchConnectivity and never
/// reads or writes the saved snapshot, so the real data is untouched. Adding `-Screen <name>`
/// opens one screen (see `Screen`). Debug builds only: Release ignores the arguments, so none of
/// this can be reached in the App Store build.
enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()

    /// The screens the script captures, by the name passed after `-Screen`, in order.
    enum Screen: String, CaseIterable {
        /// Tonight: dinner, when to start, Start Cooking, and what's next.
        case tonight
        /// Cooking from the wrist: the roasting step, with its timer button.
        case cook
        /// The grocery list, a few things already checked off.
        case grocery
        /// Tell the Pantry, after the phone put away what was said.
        case pantry
    }

    static let screen: Screen? = {
        guard isOn else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-Screen"), arguments.indices.contains(index + 1) else { return .tonight }
        return Screen(rawValue: arguments[index + 1]) ?? .tonight
    }()

    /// The page RootView opens on.
    static var page: RootView.Page {
        switch screen {
        case .grocery: .grocery
        case .pantry: .pantry
        default: .tonight
        }
    }

    /// The step CookView opens on (0 outside screenshot mode).
    static var cookStep: Int { screen == .cook ? 2 : 0 }

    /// The time Tonight picks the next meal for: late afternoon, before dinner.
    static var clock: Date {
        Calendar.current.date(bySettingHour: 16, minute: 30, second: 0, of: .now) ?? .now
    }

    // MARK: Demo content

    static let fajitas = WatchRecipe(
        id: "r-fajitas",
        title: "Sheet-Pan Chicken Fajitas",
        steps: [
            "Heat the oven to 425°F.",
            "Toss the chicken, peppers and onion with the oil and seasoning on two sheet pans.",
            "Roast 22 to 25 minutes, switching the pans halfway.",
            "Squeeze the limes over and serve with warm tortillas.",
        ].map { WatchStep(text: $0, timerSeconds: StepTimer.seconds(in: $0)) }
    )

    static func snapshot(now: Date = .now, calendar: Calendar = .current) -> WatchSnapshot {
        let today = calendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        func meal(_ day: Int, _ slot: String, _ hour: Int, _ title: String, minutes: Int?, recipes: [WatchRecipe] = []) -> WatchMeal {
            WatchMeal(id: "demo-\(day)-\(slot)", slot: slot, startsAt: at(day, hour), title: title,
                      servings: 6, minutes: minutes, recipes: recipes, completed: false)
        }
        func item(_ id: String, _ name: String, _ quantity: String, _ note: String? = nil) -> WatchGroceryItem {
            WatchGroceryItem(id: "demo.\(id)", name: name, quantity: quantity, note: note)
        }
        let grocery = WatchGrocery(
            id: "demo-week",
            sections: [
                WatchGrocerySection(name: "Produce", icon: "leaf", items: [
                    item("peppers", "Bell peppers", "3", "For Fajitas"),
                    item("onion", "Red onion", "1"),
                    item("limes", "Limes", "2"),
                    item("beans", "Green beans", "2 lb"),
                    item("apples", "Apples", "6"),
                ]),
                WatchGrocerySection(name: "Meat & Seafood", icon: "fish", items: [
                    item("chicken", "Chicken breasts", "3 lb", "For Fajitas"),
                    item("turkey", "Ground turkey", "2 lb", "For Chili"),
                ]),
                WatchGrocerySection(name: "Dairy & Eggs", icon: "drop", items: [
                    item("milk", "Milk", "1 gal"),
                    item("parmesan", "Parmesan", "1 cup"),
                    item("eggs", "Eggs", "1 dozen"),
                ]),
                WatchGrocerySection(name: "Bakery", icon: "birthday.cake", items: [
                    item("tortillas", "Flour tortillas", "16"),
                ]),
            ],
            checks: ["demo.onion": true, "demo.limes": true, "demo.milk": true]
        )
        return WatchSnapshot(
            generatedAt: now,
            meals: [
                meal(0, "dinner", 18, "Sheet-Pan Chicken Fajitas", minutes: 40, recipes: [fajitas]),
                meal(1, "breakfast", 8, "Blueberry Buttermilk Pancakes", minutes: 25),
                meal(1, "dinner", 18, "Slow-Cooker Turkey Chili", minutes: 20),
            ],
            grocery: grocery
        )
    }

    /// Tell the Pantry, done: what was said and what the phone changed.
    static var pantryRequest: WatchStore.PantryRequest? {
        guard screen == .pantry else { return nil }
        return WatchStore.PantryRequest(
            id: "demo-pantry",
            text: "Two gallons of milk, a dozen eggs, and we're out of tortillas",
            status: .done([
                WatchPantryLine(name: "Milk", change: "+2 gal", detail: "2 gal · Fridge"),
                WatchPantryLine(name: "Eggs", change: "+12", detail: "12 · Fridge"),
                WatchPantryLine(name: "Flour tortillas", change: "Out", detail: "Added to Grocery"),
            ])
        )
    }
}
