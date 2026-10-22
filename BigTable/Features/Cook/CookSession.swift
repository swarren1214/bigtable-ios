import Foundation
import Observation
import SwiftUI
import UserNotifications

/// The recipe being cooked: which step you're on, the amounts you chose and the kitchen timer.
/// One for the app (`shared`), above every pose-specific view, so folding, opening or closing
/// the phone never loses the step or a running timer (iPhone Duo: "state follows the hand").
/// Cook Mode (Laptop), the recipe page and the Across the Kitchen board (Tent) all read and
/// move the same step.
@MainActor
@Observable
final class CookSession {
    static let shared = CookSession()

    /// The recipe being cooked, or nil.
    private(set) var recipeID: String?
    private(set) var title = ""
    private(set) var steps: [String] = []
    private(set) var ingredients: [RecipeIngredient] = []
    private(set) var baseServings: Double = 0
    private(set) var servings = 1
    private(set) var scaleEnabled = false
    private(set) var amountStyle: RecipeAmountStyle = .fraction
    private(set) var stepIndex = 0

    /// The Across the Kitchen board (Tent), opened from Cook Mode's toolbar.
    var showsBoard = false

    // The timer: one at a time, like a kitchen timer (as on the watch). It runs from an end
    // date, so it keeps time when the phone is closed or the app is in the background, and a
    // notification says when it's done.
    private(set) var timerLabel = ""
    private(set) var timerDuration: TimeInterval = 0
    /// While running.
    private(set) var timerEndsAt: Date?
    /// While paused: what was left.
    private(set) var timerPausedRemaining: TimeInterval?

    var isCooking: Bool { recipeID != nil }
    var hasTimer: Bool { timerEndsAt != nil || timerPausedRemaining != nil }
    var isTimerPaused: Bool { timerPausedRemaining != nil }

    var currentStep: String { steps.indices.contains(stepIndex) ? steps[stepIndex] : "" }
    var nextStep: String? { steps.indices.contains(stepIndex + 1) ? steps[stepIndex + 1] : nil }
    var isFirstStep: Bool { stepIndex == 0 }
    var isLastStep: Bool { stepIndex >= steps.count - 1 }

    // MARK: Cooking

    /// Starts cooking a recipe at its first step (or picks up where it was, for the same recipe).
    func start(_ detail: RecipeDetail, servings: Int, scaleEnabled: Bool, amountStyle: RecipeAmountStyle) {
        let steps = detail.instructions.map(RecipeFormat.stripStepNumber).filter { !$0.isEmpty }
        if recipeID != detail.id {
            stopTimer()
            stepIndex = 0
        }
        recipeID = detail.id
        title = detail.title
        self.steps = steps
        ingredients = detail.ingredients
        baseServings = detail.baseServings
        self.servings = servings
        self.scaleEnabled = scaleEnabled
        self.amountStyle = amountStyle
        stepIndex = min(stepIndex, max(steps.count - 1, 0))
    }

    /// The recipe page's servings or amount style changed while cooking it.
    func updateAmounts(recipeID: String, servings: Int, scaleEnabled: Bool, amountStyle: RecipeAmountStyle) {
        guard self.recipeID == recipeID else { return }
        self.servings = servings
        self.scaleEnabled = scaleEnabled
        self.amountStyle = amountStyle
    }

    /// Done cooking: forgets the recipe and stops the timer.
    func finish() {
        stopTimer()
        showsBoard = false
        recipeID = nil
        title = ""
        steps = []
        ingredients = []
        stepIndex = 0
    }

    func next() {
        guard stepIndex < steps.count - 1 else { return }
        stepIndex += 1
    }

    func back() {
        guard stepIndex > 0 else { return }
        stepIndex -= 1
    }

    /// The time the current step names ("simmer 15 minutes"), for its timer button.
    var currentStepSeconds: Int? { StepTimer.seconds(in: currentStep) }

    /// The current step's ingredients: those whose name the step mentions. Recipes don't link
    /// ingredients to steps, so this reads the step's words; it can miss one ("the sauce").
    var currentStepIngredients: [RecipeIngredient] {
        let text = currentStep.lowercased()
        guard !text.isEmpty else { return [] }
        return ingredients.filter { ingredient in
            Self.keywords(for: amountParts(ingredient).name).contains { text.contains($0) }
        }
    }

    /// "1 ½ cup" and "flour", scaled the way the recipe page showed it.
    func amountParts(_ ingredient: RecipeIngredient) -> (quantity: String, name: String) {
        RecipeAmounts.parts(ingredient, base: baseServings, servings: servings, scaleEnabled: scaleEnabled, style: amountStyle)
    }

    private static let ignoredWords: Set<String> = [
        "fresh", "large", "small", "medium", "chopped", "diced", "sliced", "minced", "ground",
        "whole", "optional", "taste", "plus", "more", "about", "into", "with", "cups", "each",
        "pieces", "piece", "finely", "roughly", "divided", "softened", "melted", "packed", "extra",
    ]

    /// The words of an ingredient's name worth looking for in a step: "chicken thighs" →
    /// "chicken", "thigh".
    static func keywords(for name: String) -> [String] {
        let words = name.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 }
        return words.compactMap { word -> String? in
            guard !ignoredWords.contains(word) else { return nil }
            // "tomatoes" → "tomato", "onions" → "onion": a step may name one.
            if word.hasSuffix("oes") { return String(word.dropLast(2)) }
            if word.hasSuffix("s"), word.count > 4 { return String(word.dropLast()) }
            return word
        }
    }

    // MARK: Timer

    func remaining(at now: Date = .now) -> TimeInterval {
        if let timerPausedRemaining { return timerPausedRemaining }
        guard let timerEndsAt else { return 0 }
        return max(0, timerEndsAt.timeIntervalSince(now))
    }

    /// Starts the current step's timer.
    func startStepTimer() {
        guard let seconds = currentStepSeconds else { return }
        startTimer(seconds: seconds, label: Self.timerName(for: currentStep, number: stepIndex))
    }

    func startTimer(seconds: Int, label: String) {
        timerLabel = label
        timerDuration = TimeInterval(seconds)
        timerPausedRemaining = nil
        timerEndsAt = .now.addingTimeInterval(timerDuration)
        scheduleAlert()
    }

    func toggleTimerPause() {
        if let timerPausedRemaining {
            timerEndsAt = .now.addingTimeInterval(timerPausedRemaining)
            self.timerPausedRemaining = nil
        } else if timerEndsAt != nil {
            timerPausedRemaining = remaining()
            timerEndsAt = nil
        }
        scheduleAlert()
    }

    func addMinute() {
        if let timerPausedRemaining {
            self.timerPausedRemaining = timerPausedRemaining + 60
        } else if let timerEndsAt {
            self.timerEndsAt = max(timerEndsAt, .now).addingTimeInterval(60)
        }
        timerDuration += 60
        scheduleAlert()
    }

    func stopTimer() {
        timerEndsAt = nil
        timerPausedRemaining = nil
        timerLabel = ""
        scheduleAlert()
    }

    /// What a timer is for: the step's first word when it reads like a verb ("Simmer",
    /// "Bake"), otherwise "Step 5". The same rule as the watch's Cook view.
    nonisolated static func timerName(for step: String, number: Int) -> String {
        let first = step.split(separator: " ").first.map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
        if first.count >= 3, first.count <= 12, first.allSatisfy(\.isLetter) {
            return first.prefix(1).uppercased() + first.dropFirst().lowercased()
        }
        return "Step \(number + 1)"
    }

    /// "4:59", or "1:04:59" for an hour or more.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let duration = Duration.seconds(Int(seconds.rounded(.up)))
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    /// "15 min" ("45 sec" for a step under a minute), for a Start Timer button.
    nonisolated static func shortDuration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    private static let alertID = "bigtable.cook-timer"

    /// The notification for when the timer's done (replaced on every change). Only the
    /// recipe's title and the timer's label, nothing about the household.
    private func scheduleAlert() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.alertID])
        guard let timerEndsAt else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(timerLabel) is done"
        if !title.isEmpty { content.body = title }
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, timerEndsAt.timeIntervalSinceNow), repeats: false)
        // As the watch's CookTimer does it.
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(UNNotificationRequest(identifier: Self.alertID, content: content, trigger: trigger))
        }
    }
}

/// An ingredient's amount and name for showing: scaled to the chosen servings when scaling is
/// on, as kitchen fractions or decimals. Ingredients imported as one line ("2 cups flour") with
/// no amount are read the way the Expo app did. Shared by the recipe page and Cook Mode.
nonisolated enum RecipeAmounts {
    static func parts(_ ingredient: RecipeIngredient, base: Double, servings: Int, scaleEnabled: Bool, style: RecipeAmountStyle) -> (quantity: String, name: String) {
        var amount = ingredient.amount
        var measurement = ingredient.measurementType
        var name = ingredient.name
        if amount == nil {
            let parsed = Ingredients.parseLine(ingredient.name)
            if let parsedAmount = parsed.amount {
                amount = parsedAmount
                measurement = measurement ?? parsed.measurementType
                name = parsed.name.isEmpty ? ingredient.name : parsed.name
            }
        }
        let factor = scaleEnabled && base > 0 ? Double(servings) / base : 1
        let quantity: String
        if let amount {
            let scaled = amount * factor
            quantity = style == .fraction ? Ingredients.displayAmount(scaled) : Ingredients.formatAmount(scaled)
        } else {
            quantity = ""
        }
        let unit = Ingredients.shortLabel(measurement)
        return ([quantity, unit].filter { !$0.isEmpty }.joined(separator: " "), name)
    }
}
