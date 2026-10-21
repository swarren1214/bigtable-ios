import SwiftUI
import UIKit

/// Ask BigTable, from the ✨ button at the top of every tab: questions about the plan, recipes
/// and the grocery list, answered by Apple's on-device model. It can also change things: put a
/// meal on the plan, add to the list, check things off. Each change shows as a card with Undo.
/// Type, tap a suggestion, or tap the mic to talk hands free.
struct AskView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var engine = AskEngine.shared
    @State private var draft = ""
    @State private var showsVoice = false
    @State private var suggestions: [String] = []
    @FocusState private var composerFocused: Bool

    /// One line of the message field, and the round button beside it.
    private static let composerHeight: CGFloat = 46

    private var isAvailable: Bool { engine.availability == .available }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if engine.messages.isEmpty {
                            welcome
                        }
                        ForEach(engine.messages) { message in
                            AskMessageRow(message: message, engine: engine)
                                .id(message.id)
                        }
                        if engine.isThinking {
                            AskThinkingRow()
                                .id("thinking")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: engine.messages.count) {
                    if let last = engine.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    refreshSuggestions()
                }
                .onChange(of: engine.isThinking) { _, thinking in
                    if thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }
            composer
        }
        .background(Color(.systemGroupedBackground))
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showsVoice) {
            AskVoiceView {
                // Type: the message field takes over.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    composerFocused = true
                }
            } onEnd: { showList in
                showsVoice = false
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if showList { AppRouter.shared.tab = .grocery }
                    dismiss()
                }
            }
            .tint(accent)
            .environment(\.accent, accent)
        }
        .task {
            refreshSuggestions()
            engine.prewarm()
            await engine.household.prepare()
            refreshSuggestions()
        }
    }

    // MARK: Header

    /// Close, the title with its sparkles, and hands-free voice.
    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close")

            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Ask BigTable")
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()

            Button {
                openVoice()
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(!isAvailable)
            .accessibilityLabel("Talk hands free")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about meals or the list.")
                .font(.title2.bold())
            Text("What’s planned, what to make, what’s still needed. BigTable can also put a meal on the plan, add to the grocery list or check things off, and every change can be undone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !isAvailable {
                Text(engine.availability.message)
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskStyle.cardBackground, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.top, 4)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 10) {
            if !suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                ask(suggestion)
                            } label: {
                                Text(suggestion)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 34)
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .background(Color(.tertiarySystemFill), in: .capsule)
                            .disabled(engine.isThinking || !isAvailable)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel("Suggestions")
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about meals or the list", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: Self.composerHeight)
                    .background(AskStyle.cardBackground, in: .rect(cornerRadius: Self.composerHeight / 2, style: .continuous))

                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        openVoice()
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: Self.composerHeight, height: Self.composerHeight)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(accent, in: .circle)
                    .disabled(!isAvailable)
                    .opacity(isAvailable ? 1 : 0.5)
                    .accessibilityLabel("Talk")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: Self.composerHeight, height: Self.composerHeight)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(accent, in: .circle)
                    .disabled(engine.isThinking)
                    .opacity(engine.isThinking ? 0.5 : 1)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 6) {
                Image(systemName: DeviceName.current == "iPad" ? "ipad" : "iphone")
                Text("Answers on your \(DeviceName.current) · changes save to the household")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            if !engine.messages.isEmpty {
                Button("Clear") {
                    withAnimation(.snappy) { engine.reset() }
                    refreshSuggestions()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .disabled(engine.isThinking)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }

    private func send() {
        let text = draft
        draft = ""
        ask(text)
    }

    private func ask(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await engine.send(text) }
    }

    private func openVoice() {
        guard isAvailable else { return }
        composerFocused = false
        showsVoice = true
    }

    private func refreshSuggestions() {
        suggestions = AskSuggestions.current()
    }
}

// MARK: - Suggestions

/// A few starters that fit what's going on: tonight's dinner, what's left to buy, an open
/// night to plan, and adding to the list.
enum AskSuggestions {
    static func current() -> [String] {
        var list = ["What’s for dinner tonight?"]
        let grocery = GroceryStore.shared
        if grocery.remainingCount > 0 {
            list.append("What do I still need from the store?")
        }
        let today = PlanDates.todayISO
        let weekStart = ISODay.weekStart(containing: .now)
        if AppModel.shared.canManagePlan, let planner = PlanStore.shared.planner(weekStart) {
            let rest = PlanDates.dates(from: today, to: ISODay.adding(days: 6, to: weekStart))
            if let open = rest.dropFirst().first(where: { planner.slot(PlanDates.day(forISO: $0), .dinner).isEmpty }) {
                list.append("Plan dinner for \(PlanDates.day(forISO: open).label)")
            }
        }
        list.append("What’s for dinner this week?")
        if AppModel.shared.isOrganizer {
            list.append("Add milk to the list")
        }
        return list
    }
}

// MARK: - Messages

/// One message: the question in the accent color on the right, the answer as plain text with
/// its cards on the left.
struct AskMessageRow: View {
    var message: AskMessage
    var engine: AskEngine
    @Environment(\.accent) private var accent

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(accent, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    Text(AskFormatting.attributed(message.text))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .tint(.primary)
                }
                ForEach(message.actions) { action in
                    AskActionCard(action: action) {
                        Task { await engine.toggle(action.id, in: message.id) }
                    } onResolve: { replace in
                        Task { await engine.resolve(action.id, in: message.id, replace: replace) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 24)
        case .notice:
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }
}

/// Three dots that pulse in turn while BigTable works on an answer.
struct AskThinkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let phase = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate * 3) % 3
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color(.systemGray3).opacity(index == phase ? 1 : 0.45))
                            .frame(width: 7, height: 7)
                    }
                }
            }
            Text("Checking…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

enum AskFormatting {
    /// The reply with any inline Markdown, or the plain text if it isn't valid Markdown.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
