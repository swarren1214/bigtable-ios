import AuthenticationServices
import SwiftUI

/// BigTable's first run, from the Hearth Onboarding canvas: Welcome (Sign in with Apple, or carry
/// on without), the household (HearthKit's shared step, which says so when another Hearth app
/// already made it), what you like to eat, when you eat, how you shop, the first week, All Set,
/// and Better with Hearth. Someone joining another family's household skips straight from the
/// household to All Set (the organizer runs the kitchen).
///
/// Built from HearthOnboarding.swift. Shown once per install over everything (`AppRoot`), never
/// to someone who used BigTable before (`isNeeded`).
struct BigTableOnboarding: View {
    /// Onboarding is over (Plan with AI opens next when they asked for it).
    var onFinish: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.accent) private var accent
    @AppStorage(SettingsKey.warehouseSizes) private var warehouseSizes = true

    @State private var screen: Screen = .welcome
    @State private var forward = true
    @State private var tastes: Set<String> = []
    @State private var times = HearthMealTimes.current
    @State private var shopping: Shopping = .store
    @State private var planWeek = true
    @State private var errorMessage: String?

    private let household = HearthHouseholdStore.shared
    private let app = HearthApp.bigtable

    enum Screen: Int, Comparable {
        case welcome, household, tastes, times, shopping, firstWeek, allSet, hearth

        static func < (a: Screen, b: Screen) -> Bool { a.rawValue < b.rawValue }
    }

    enum Shopping { case store, warehouse }

    /// Cuisines and kinds of cooking, saved to your likes in the household (the AI planner reads
    /// everyone's likes, dislikes and allergies).
    static let tasteOptions = ["Mexican", "Italian", "Asian", "Comfort food", "Grilling", "Meatless nights", "Slow cooker", "Breakfast for dinner", "Soups", "Sheet-pan", "Kid favorites"]

    /// A member of another family's kitchen: the organizer sets tastes, times and the plan.
    private var isMember: Bool { household.isMember }

    var body: some View {
        ZStack {
            page
                .id(screen)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                ))
        }
        .animation(.smooth, value: screen)
        .hearthOnboardingStyle(app)
        .errorAlert($errorMessage, title: "Couldn't sign in")
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var page: some View {
        switch screen {
        case .welcome: welcome
        case .household:
            HearthHouseholdOnboarding(accent: accent) {
                model.markSetUp()
                go(isMember ? .allSet : .tastes)
            }
        case .tastes: tastesPage
        case .times: timesPage
        case .shopping: shoppingPage
        case .firstWeek: firstWeekPage
        case .allSet: allSetPage
        case .hearth:
            HearthOnboardingAppsPage(app: app) { tour in finish(tour: tour) }
        }
    }

    private func go(_ next: Screen) {
        forward = next > screen
        screen = next
    }

    // MARK: Welcome

    private var welcome: some View {
        HearthOnboardingPage(app: app, title: "BigTable", subtitle: "Meal planning and grocery lists for big families.") {
            VStack(spacing: 20) {
                HearthOnboardingFeature(app: app, symbol: "calendar", title: "Plan the week together", detail: "Breakfast, lunch and dinner for everyone at the table.")
                HearthOnboardingFeature(app: app, symbol: "cart", title: "One grocery list", detail: "Built from the plan and sorted by aisle.")
                HearthOnboardingFeature(app: app, symbol: "person.2", title: "Made for big families", detail: "Ages, likes and allergies shape every suggestion.")
            }
        } controls: {
            if model.isSignedIn {
                HearthOnboardingButtons(app: app, primary: "Continue", action: { go(.household) }, footnote: "Signed in with your Hearth account.")
            } else {
                AccountAppleSignInButton(label: .signIn) { message in
                    errorMessage = message
                } onSuccess: {
                    go(.household)
                }
                HearthOnboardingButtons(
                    app: app,
                    secondary: "Continue Without an Account", secondaryAction: { go(.household) },
                    footnote: "Optional. Community and planning with AI need it. Your recipes and plans live in your iCloud."
                )
            }
        }
    }

    // MARK: Tastes

    private var tastesPage: some View {
        HearthOnboardingPage(app: app, step: (2, 5), symbol: "heart", title: "What do you like to eat?", subtitle: "Tap what’s a hit. BigTable plans around everyone’s tastes.") {
            HearthOnboardingChips(options: Self.tasteOptions, selection: $tastes)
            HearthOnboardingNote(allergyNote)
        } controls: {
            HearthOnboardingButtons(app: app, primary: "Continue", action: {
                saveTastes()
                go(.times)
            }, secondary: "Skip", secondaryAction: { go(.times) })
        }
    }

    /// Everyone's allergies, from the household.
    private var allergies: [String] {
        var seen: Set<String> = []
        return household.people.filter { !$0.isArchived }.flatMap(\.allergies).filter { seen.insert($0.lowercased()).inserted }
    }

    private var allergyNote: String {
        let list = allergies
        guard !list.isEmpty else { return "Add each person’s likes and allergies anytime in Household." }
        return "Allergies come from your household: \(list.prefix(3).joined(separator: ", ").lowercased()) are never planned."
    }

    /// Adds the picks to your own likes in the household, beside any already there.
    private func saveTastes() {
        guard !tastes.isEmpty, var me = household.me else { return }
        let existing = Set(me.likes.map { $0.lowercased() })
        me.likes += Self.tasteOptions.filter { tastes.contains($0) && !existing.contains($0.lowercased()) }
        household.save(me)
    }

    // MARK: Meal times

    private var timesPage: some View {
        HearthOnboardingPage(app: app, step: (3, 5), symbol: "clock", title: "When do you eat?", subtitle: "So meals show up at the right time on Caloma’s family calendar.") {
            HearthOnboardingCard {
                timeRow("Breakfast", \.breakfast)
                timeRow("Lunch", \.lunch)
                timeRow("Dinner", \.dinner)
            }
            HearthOnboardingNote("Change them anytime in Profile › Meal Times.")
        } controls: {
            HearthOnboardingButtons(app: app, primary: "Continue", action: {
                _ = Hearth.publish(times, from: .bigtable)
                go(.shopping)
            }, secondary: "Skip", secondaryAction: { go(.shopping) })
        }
    }

    private func timeRow(_ title: String, _ key: WritableKeyPath<HearthMealTimes, Int>) -> some View {
        DatePicker(title, selection: Binding(
            get: { Calendar.current.date(bySettingHour: times[keyPath: key] / 60, minute: times[keyPath: key] % 60, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                times[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
    }

    // MARK: Shopping

    private var shoppingPage: some View {
        HearthOnboardingPage(app: app, step: (4, 5), symbol: "cart", title: "How do you shop?", subtitle: "Grocery lists made with AI come in the sizes you buy.") {
            HearthOnboardingOption("Grocery store", detail: "Everyday sizes", isSelected: shopping == .store) { shopping = .store }
            HearthOnboardingOption("Warehouse club", detail: "Rounded up to bulk sizes", isSelected: shopping == .warehouse) { shopping = .warehouse }
        } controls: {
            HearthOnboardingButtons(app: app, primary: "Continue", action: {
                warehouseSizes = shopping == .warehouse
                go(.firstWeek)
            }, secondary: "Skip", secondaryAction: { go(.firstWeek) })
        }
    }

    // MARK: First week

    private var firstWeekPage: some View {
        HearthOnboardingPage(app: app, step: (5, 5), symbol: "sparkles", title: "Plan your first week", subtitle: "BigTable can fill in the week from what everyone likes. Change anything after.") {
            HearthOnboardingOption("Plan it for me", detail: "Right after this, with Plan with AI", isSelected: planWeek) { planWeek = true }
            HearthOnboardingOption("I’ll add meals myself", detail: "Start with an empty week", isSelected: !planWeek) { planWeek = false }
            HearthOnboardingNote("Planning with AI is part of BigTable Plus and Hearth+, and needs Sign in with Apple.")
        } controls: {
            HearthOnboardingButtons(app: app, primary: "Continue", action: { go(.allSet) })
        }
    }

    // MARK: All set

    private var allSetPage: some View {
        HearthOnboardingPage(app: app, symbol: "checkmark", title: "You’re all set", subtitle: isMember ? "You’re cooking from \(household.info?.name ?? "your family’s") kitchen." : "Here’s your kitchen.") {
            VStack(spacing: 14) {
                ForEach(summary) { line in
                    HearthOnboardingSummaryRow(app: app, title: line.title, detail: line.detail)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22, style: .continuous))
        } controls: {
            HearthOnboardingButtons(app: app, primary: "Continue", action: { go(.hearth) })
        }
    }

    private struct Line: Identifiable {
        var title: String
        var detail: String
        var id: String { title }
    }

    private var summary: [Line] {
        let people = household.people.filter { !$0.isArchived }.count
        var lines = [
            Line(title: people == 1 ? "A household of 1" : "\(people) people at your table", detail: household.info?.name ?? "Your household"),
        ]
        let list = allergies
        lines.append(list.isEmpty
            ? Line(title: "No allergies yet", detail: "Add them for anyone in Household")
            : Line(title: "Never planned: \(list.prefix(3).joined(separator: ", ").lowercased())", detail: "From your household’s allergies"))
        if !isMember {
            let dinner = Calendar.current.date(bySettingHour: times.dinner / 60, minute: times.dinner % 60, second: 0, of: .now) ?? .now
            lines.append(Line(title: "Dinner at \(dinner.formatted(date: .omitted, time: .shortened))", detail: "On Caloma’s family calendar too"))
            if !tastes.isEmpty {
                lines.append(Line(title: "\(tastes.count) favorites", detail: Self.tasteOptions.filter { tastes.contains($0) }.prefix(3).joined(separator: ", ")))
            }
            lines.append(planWeek
                ? Line(title: "Your first week next", detail: "Plan with AI opens after this")
                : Line(title: "An empty week to fill", detail: "Tap any day on Plan to add a meal"))
        }
        return lines
    }

    // MARK: Finishing

    private func finish(tour: Bool) {
        let plan = planWeek && !isMember
        // Plan with AI comes first when they asked for it; the tour stays in Profile › Take the Tour.
        HearthOnboarding.finish(.bigtable, tour: tour && !plan)
        model.markSetUp()
        model.markTutorialComplete()
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        onFinish()
        if plan {
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                router.present(.aiPlan)
            }
        }
    }

    // MARK: Who sees it

    static let doneKey = "bigtable.onboarded"

    /// A new install of BigTable: not set up before on this device, not an account that's been
    /// through the old tutorial, and no kitchen. Someone who used BigTable before is marked done
    /// here so they never see it. Ask again when the phase or the account changes.
    @MainActor
    static func isNeeded(_ model: AppModel) -> Bool {
        let defaults = UserDefaults.standard
        guard !ScreenshotMode.isOn, !defaults.bool(forKey: doneKey) else { return false }
        // Signed in (everyone who used BigTable before was): wait for the account to load, so
        // an account that's been through the old tutorial is recognized. Not decided yet.
        if model.isSignedIn && model.me == nil { return false }
        KitchenStore.shared.prepare()
        let kitchen = KitchenStore.shared.state
        let usedBefore = defaults.bool(forKey: "bigtable.setUp")
            || model.userID.map { defaults.bool(forKey: "bigtable.setUp.\($0)") } == true
            || model.me?.profile?.tutorialComplete == true
            || !kitchen.recipes.isEmpty || !kitchen.slots.isEmpty
        if usedBefore {
            defaults.set(true, forKey: doneKey)
            return false
        }
        return true
    }
}
