import Foundation
import FoundationModels
import Observation
import OSLog

// MARK: - Messages

/// One message in the Ask BigTable conversation.
struct AskMessage: Identifiable {
    enum Role { case user, assistant, notice }

    let id = UUID()
    var role: Role
    var text: String
    /// What the answer changed or looked up, drawn as cards under the reply (with Undo).
    var actions: [AskAction] = []
    /// The grocery aisle the answer was about, for the live card on the voice screen.
    var focusSection: String?
}

/// Something a reply did, shown as a card. Changes keep what's needed to undo and redo them.
struct AskAction: Identifiable {
    enum Kind {
        /// A list of days and what's planned (for "what's for dinner this week?").
        case week(AskWeekCard)
        /// A meal put on the plan, or one waiting for Replace or Keep.
        case plan(AskPlanChange)
        /// Things added to the grocery list.
        case groceryAdd(AskGroceryChange)
        /// Things checked off the grocery list.
        case groceryCheck(AskGroceryChange)
    }

    let id = UUID()
    var kind: Kind
    /// An Undo, Redo, Replace or Keep is saving.
    var isBusy = false
}

/// The week card: one row per day.
struct AskWeekCard {
    struct Row: Identifiable {
        let id = UUID()
        /// "MON".
        var day: String
        /// Nil when nothing is planned.
        var title: String?
        var imageUrl: String?
    }

    var rows: [Row]
}

/// A meal Ask put on the plan (or offered to).
struct AskPlanChange {
    enum Status {
        /// The slot already had a meal: waiting for Replace or Keep.
        case needsConfirmation
        case done
        case undone
        /// They chose Keep.
        case kept
    }

    var ref: PlanSlotRef
    /// The new meal's name.
    var title: String
    var imageUrl: String?
    /// "Thursday dinner · serves 8".
    var detail: String
    /// What was there before (restored by Undo).
    var before: PlannerSlot
    /// The new meal (restored by Redo).
    var after: PlannerSlot
    /// The meal already planned, when it needs confirmation.
    var existingTitle: String?
    var status: Status
}

/// Grocery items Ask added or checked off.
struct AskGroceryChange {
    var items: [AskGroceryLine]
    /// Undo was tapped (Redo shows instead).
    var undone = false
}

struct AskGroceryLine: Identifiable {
    let id = UUID()
    /// The grocery item's id on the list (a re-added item gets a new one).
    var itemID: String
    var name: String
    var quantity: String
    var section: String
}

// MARK: - Availability

/// Whether Apple's on-device model can run here, and what to say when it can't.
enum AskAvailability: Equatable {
    case available
    /// Supported device, but Apple Intelligence is turned off.
    case notEnabled
    /// Turned on, but the model is still downloading.
    case notReady
    /// This device can't run the on-device model.
    case unsupported

    static var current: AskAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .notReady
        case .unavailable: return .unsupported
        }
    }

    var message: String {
        switch self {
        case .available: ""
        case .notEnabled: "Ask BigTable runs on your \(DeviceName.current)’s built-in AI, which is turned off. You can turn on Apple Intelligence in Settings."
        case .notReady: "Your \(DeviceName.current)’s built-in AI is still getting ready. Try again in a little while."
        case .unsupported: "Ask BigTable needs a newer \(DeviceName.current) with Apple Intelligence. Everything else in BigTable works without it."
        }
    }
}

// MARK: - Engine

/// The Ask BigTable conversation, on Apple's on-device model. The model reads and changes the
/// plan and the grocery list through tools (AskTools.swift); every change it makes is added to
/// its reply as a card with Undo. Free for everyone: nothing leaves the device except the
/// changes themselves, which save to the household like any other edit.
@Observable
final class AskEngine {
    static let shared = AskEngine()

    private(set) var messages: [AskMessage] = []
    private(set) var isThinking = false

    /// The plan, recipes and grocery list, for the tools.
    let household = AskHousehold()

    /// One session per conversation, so follow-ups ("and Friday?") have context.
    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "ask")

    static var isAvailable: Bool { AskAvailability.current == .available }
    var availability: AskAvailability { AskAvailability.current }

    /// Loads the model ahead of the first question, so the first answer comes sooner.
    func prewarm() {
        guard Self.isAvailable, session == nil else { return }
        let session = makeSession()
        session.prewarm()
        self.session = session
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            tools: [
                PlanLookupTool(household: household),
                RecipeSearchTool(household: household),
                PlanMealTool(household: household),
                AddGroceryTool(household: household),
                CheckOffGroceryTool(household: household),
                GroceryListTool(household: household),
            ],
            instructions: Self.instructions()
        )
    }

    /// What the model is told about BigTable and this household, with today's date.
    static func instructions() -> String {
        let model = AppModel.shared
        let names = model.members.map(\.name).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let people = names.isEmpty ? "" : " The household: \(names.count) people (\(names.joined(separator: ", ")))."
        let times = HearthMealTimes.current
        func time(_ slot: String) -> String {
            times.start(for: slot, on: .now).formatted(date: .omitted, time: .shortened)
        }
        return """
        You are BigTable, the meal-planning helper for a big family, talking with someone in the household by text or out loud. \
        Today is \(Date.now.formatted(date: .complete, time: .omitted)) and it's \(Date.now.formatted(date: .omitted, time: .shortened)) now. Weeks start on Sunday.\(people) \
        Meals are at \(time("breakfast")) breakfast, \(time("lunch")) lunch and \(time("dinner")) dinner; "tonight" means today's dinner.

        How to answer:
        - One to three short, friendly sentences, like a person talking. Lead with the answer.
        - No lists, headings, emoji or markdown: the app shows the details in cards.
        - Don't repeat the question or offer more help.

        Rules:
        - Always use a tool to read or change the plan or the grocery list. Never guess what's planned or what's on the list.
        - getMealPlan for what's planned. findRecipes to look through the family's recipes. planMeal to put a meal on the plan. \
        addGroceryItems to add to the grocery list. checkOffGroceryItems when they got something or want it crossed off. getGroceryList for what's still needed.
        - Only say something changed when the tool says it did. If planMeal says it needs confirmation, ask whether to replace the meal that's there; don't say it's done.
        - If a tool says they aren't allowed to do something, say so kindly.
        - Only help with meals, recipes, the meal plan and groceries.
        """
    }

    func send(_ text: String) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        messages.append(AskMessage(role: .user, text: question))

        let status = AskAvailability.current
        guard status == .available else {
            messages.append(AskMessage(role: .notice, text: status.message))
            return
        }
        isThinking = true
        defer { isThinking = false }
        household.beginTurn()

        do {
            let reply = try await respond(to: question, retrying: true)
            var message = AskMessage(role: .assistant, text: AskText.clean(reply))
            message.actions = household.takeActions()
            message.focusSection = household.focusSection
            messages.append(message)
        } catch {
            log.error("Ask failed: \(String(describing: error), privacy: .public)")
            // Anything the tools already changed still gets its card (and its Undo).
            let actions = household.takeActions()
            if !actions.isEmpty {
                var message = AskMessage(role: .assistant, text: "")
                message.actions = actions
                message.focusSection = household.focusSection
                messages.append(message)
            }
            messages.append(AskMessage(role: .notice, text: Self.message(for: error)))
        }
    }

    private func respond(to question: String, retrying: Bool) async throws -> String {
        let session = self.session ?? makeSession()
        self.session = session
        do {
            return try await session.respond(to: question, options: GenerationOptions(temperature: 0.3)).content
        } catch {
            // A long conversation filled the model's context: start a fresh session and ask again.
            guard retrying, Self.isContextFull(error) else { throw error }
            self.session = makeSession()
            return try await respond(to: question, retrying: false)
        }
    }

    private static func isContextFull(_ error: Error) -> Bool {
        guard let error = error as? LanguageModelSession.GenerationError else { return false }
        if case .exceededContextWindowSize = error { return true }
        return false
    }

    /// A friendly line for what went wrong.
    static func message(for error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                return "BigTable can’t help with that one. Ask about meals, recipes, the plan or the grocery list."
            case .exceededContextWindowSize:
                return "This conversation got too long. Tap Clear and ask again."
            case .unsupportedLanguageOrLocale:
                return "BigTable can only answer in a language your \(DeviceName.current)’s built-in AI supports."
            case .assetsUnavailable:
                return "Your \(DeviceName.current)’s built-in AI is getting ready. Try again in a little while."
            default:
                break
            }
        }
        return "BigTable couldn’t answer just now. Try asking again."
    }

    /// Clear: a new conversation.
    func reset() {
        messages = []
        session = nil
    }

    // MARK: Undo, Redo, Replace and Keep

    /// Undo (or Redo) one card's change.
    func toggle(_ actionID: AskAction.ID, in messageID: AskMessage.ID) async {
        guard let action = setBusy(actionID, in: messageID, true) else { return }
        let result = await household.toggle(action.kind)
        update(actionID, in: messageID) { action in
            if let kind = result { action.kind = kind }
            action.isBusy = false
        }
        if result == nil {
            messages.append(AskMessage(role: .notice, text: "That change couldn’t be saved. Check your connection and try again."))
        }
    }

    /// Replace or Keep on a meal that was already planned.
    func resolve(_ actionID: AskAction.ID, in messageID: AskMessage.ID, replace: Bool) async {
        guard let action = setBusy(actionID, in: messageID, true) else { return }
        guard case .plan(let change) = action.kind, change.status == .needsConfirmation else {
            update(actionID, in: messageID) { $0.isBusy = false }
            return
        }
        let result = await household.resolve(change, replace: replace)
        update(actionID, in: messageID) { action in
            if let result { action.kind = .plan(result) }
            action.isBusy = false
        }
        if result == nil {
            messages.append(AskMessage(role: .notice, text: "The plan couldn’t be saved. Check your connection and try again."))
        }
    }

    /// Marks a card busy (or not) and returns it; nil when it's gone or already busy.
    private func setBusy(_ actionID: AskAction.ID, in messageID: AskMessage.ID, _ busy: Bool) -> AskAction? {
        guard let m = messages.firstIndex(where: { $0.id == messageID }),
              let a = messages[m].actions.firstIndex(where: { $0.id == actionID }) else { return nil }
        if busy, messages[m].actions[a].isBusy { return nil }
        messages[m].actions[a].isBusy = busy
        return messages[m].actions[a]
    }

    private func update(_ actionID: AskAction.ID, in messageID: AskMessage.ID, _ change: (inout AskAction) -> Void) {
        guard let m = messages.firstIndex(where: { $0.id == messageID }),
              let a = messages[m].actions.firstIndex(where: { $0.id == actionID }) else { return }
        change(&messages[m].actions[a])
    }
}

/// Text helpers for replies.
nonisolated enum AskText {
    /// The reply without markdown the model sometimes adds anyway.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased words without punctuation or accents, for comparing what was heard.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
