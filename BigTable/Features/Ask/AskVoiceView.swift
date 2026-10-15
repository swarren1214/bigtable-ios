import Foundation
import SwiftUI

/// Talking with BigTable, hands free, from the Ask · Voice design: a dark screen with a big
/// accent orb that pulses while it listens. The microphone stays on: pause for a moment and
/// BigTable answers out loud, then listens again; start talking while it speaks and it stops
/// to listen. Below the reply is a live card for the grocery aisle you're talking about, so
/// you can talk through the store. Every exchange is also added to the Ask conversation.
struct AskVoiceView: View {
    /// Type: back to the conversation, with the message field ready.
    var onType: () -> Void
    /// The red button: end, and show the list when the talk was about groceries.
    var onEnd: (_ showList: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var engine = AskEngine.shared
    @State private var conversation = AskConversation()

    private var grocery: GroceryStore { GroceryStore.shared }

    private var reply: AskMessage? {
        guard let id = conversation.replyID else { return nil }
        return engine.messages.first { $0.id == id }
    }

    /// The aisle the conversation was last about.
    private var focusName: String? {
        engine.messages.last { $0.focusSection != nil }?.focusSection
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            AskOrb(accent: accent, phase: conversation.phase, isMuted: conversation.isMuted, level: conversation.level) {
                conversation.tapOrb()
            }
            .padding(.top, 34)

            Text(phaseLabel)
                .font(.footnote.weight(.semibold))
                .tracking(1)
                .foregroundStyle(phaseColor)
                .padding(.top, 18)
                .accessibilityAddTraits(.updatesFrequently)

            VStack(spacing: 14) {
                Text(heardText)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(heardIsPlaceholder ? 0.5 : 0.92))
                    .animation(.snappy, value: heardText)
                if !replyText.isEmpty {
                    Text(replyText)
                        .font(.system(size: 17))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                if case .failed = conversation.phase {
                    Button {
                        Task { await conversation.start(with: engine) }
                    } label: {
                        Label("Try Again", systemImage: "mic.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(accent, in: .capsule)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)
            .padding(.top, 22)

            Spacer(minLength: 16)

            if let section = liveSection {
                AskLiveAisleCard(section: section, store: grocery)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }

            controls
                .padding(.top, 22)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .background(Color(red: 0.043, green: 0.043, blue: 0.047).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .animation(.snappy, value: liveSection?.name)
        .task {
            await engine.household.prepare()
            await conversation.start(with: engine)
        }
        .onDisappear { conversation.stop() }
    }

    // MARK: Header

    /// Close (back to the conversation), what's being shopped, and Type.
    private var header: some View {
        HStack {
            Button {
                conversation.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 40, height: 40)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.12), in: .circle)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityLabel("Close voice")

            Spacer()
            VStack(spacing: 2) {
                Text(grocery.hasList ? "Grocery list" : "Ask BigTable")
                    .font(.subheadline.weight(.semibold))
                if grocery.hasList, grocery.totalCount > 0 {
                    Text("\(grocery.remainingCount) left · \(grocery.checkedCount) checked")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()

            Button {
                conversation.stop()
                dismiss()
                onType()
            } label: {
                Text("Type")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.12), in: .capsule)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Words

    private var phaseLabel: String {
        if conversation.isMuted { return "MIC OFF" }
        switch conversation.phase {
        case .starting: return "STARTING"
        case .listening: return "LISTENING"
        case .thinking: return "THINKING"
        case .speaking: return "SPEAKING"
        case .micOff: return "MIC OFF"
        case .failed: return "CAN’T LISTEN"
        }
    }

    private var phaseColor: Color {
        if conversation.isMuted { return Color.white.opacity(0.5) }
        switch conversation.phase {
        case .listening: return accent
        case .thinking: return Color.white.opacity(0.7)
        case .speaking: return .white
        case .starting, .micOff, .failed: return Color.white.opacity(0.5)
        }
    }

    private var heardIsPlaceholder: Bool {
        conversation.transcript.isEmpty && conversation.question.isEmpty
    }

    /// What you're saying, or what you last asked, in quotes.
    private var heardText: String {
        if !conversation.transcript.isEmpty { return "“\(conversation.transcript)”" }
        if !conversation.question.isEmpty { return "“\(conversation.question)”" }
        return "Ask about dinner, or say what you got at the store."
    }

    private var replyText: String {
        switch conversation.phase {
        case .failed(let message):
            return message
        case .thinking, .starting:
            return ""
        case .listening, .speaking, .micOff:
            if !conversation.transcript.isEmpty { return "" }
            if let reply { return reply.text }
            return conversation.question.isEmpty && conversation.phase == .listening ? "BigTable answers when you pause." : ""
        }
    }

    /// The aisle the last answer was about, or the first one with things still needed.
    private var liveSection: GrocerySection? {
        guard grocery.hasList else { return nil }
        let aisles = grocery.orderedSections.filter { !$0.items.isEmpty }
        if let name = focusName, let match = aisles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }
        return aisles.first { aisle in aisle.items.contains { !grocery.isChecked($0) } }
    }

    // MARK: Controls

    /// The microphone on/off, and the red end button.
    private var controls: some View {
        HStack(spacing: 28) {
            Button {
                conversation.setMuted(!conversation.isMuted)
            } label: {
                Image(systemName: conversation.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(conversation.isMuted ? Color.black : Color.white)
            .background(conversation.isMuted ? Color.white : Color.white.opacity(0.12), in: .circle)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .disabled(conversation.phase == .starting)
            .accessibilityLabel(conversation.isMuted ? "Turn the microphone on" : "Turn the microphone off")

            Button {
                conversation.stop()
                onEnd(focusName != nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 64, height: 64)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color(hex: 0xD93B30), in: .circle)
            .accessibilityLabel(focusName != nil ? "End and see the list" : "End")
        }
    }
}

// MARK: - Pieces

/// The big accent circle: two rings pulse out from it while listening, it breathes while
/// speaking, and it goes gray with the microphone off. Tap it to send now or to interrupt.
struct AskOrb: View {
    var accent: Color
    var phase: AskConversation.Phase
    var isMuted: Bool
    var level: Double
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isListening: Bool { phase == .listening && !isMuted }
    private var isSpeaking: Bool { phase == .speaking }

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: reduceMotion || !(isListening || isSpeaking))) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let breathe = isSpeaking && !reduceMotion ? 0.02 * (1 - cos(time * 2 * .pi / 1.2)) : 0
                let swell = isListening ? min(level, 1) * 0.05 : 0
                ZStack {
                    if isListening && !reduceMotion {
                        ring(progress: (time / 1.8).truncatingRemainder(dividingBy: 1))
                        ring(progress: ((time + 0.9) / 1.8).truncatingRemainder(dividingBy: 1))
                    }
                    Circle()
                        .fill(RadialGradient(
                            colors: [accent.mix(with: .white, by: 0.3), accent, accent.mix(with: .black, by: 0.3)],
                            center: UnitPoint(x: 0.35, y: 0.3),
                            startRadius: 0,
                            endRadius: 110
                        ))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1).blendMode(.overlay))
                        .shadow(color: accent.opacity(0.45), radius: 25, y: 18)
                        .overlay {
                            Image(systemName: "waveform")
                                .font(.system(size: 44, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .padding(14)
                        .scaleEffect(1 + breathe + swell)
                        .saturation(isMuted ? 0.2 : 1)
                        .brightness(isMuted ? -0.3 : 0)
                }
                .frame(width: 168, height: 168)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    private func ring(progress: Double) -> some View {
        Circle()
            .fill(accent)
            .scaleEffect(1 + 0.45 * progress)
            .opacity(0.55 * (1 - progress))
    }

    private var accessibilityText: String {
        if isMuted { return "Microphone off. Double-tap to turn it on." }
        switch phase {
        case .listening: return "Listening. Double-tap to send now."
        case .thinking: return "Thinking. Double-tap to stop."
        case .speaking: return "Speaking. Double-tap to stop and listen."
        case .starting: return "Starting"
        case .micOff: return "Microphone off"
        case .failed: return "Can’t listen. Double-tap to try again."
        }
    }
}

/// One grocery aisle, live: tap an item to check it off by hand.
struct AskLiveAisleCard: View {
    var section: GrocerySection
    var store: GroceryStore

    /// Still needed first, then what's checked off; at most five.
    private var items: [GroceryItem] {
        let needed = section.items.filter { !store.isChecked($0) }
        let done = section.items.filter { store.isChecked($0) }
        return Array((needed + done).prefix(5))
    }

    var body: some View {
        let left = section.items.filter { !store.isChecked($0) }.count
        VStack(spacing: 0) {
            HStack {
                Text(section.name.uppercased())
                    .font(.footnote.weight(.bold))
                    .tracking(0.5)
                Spacer()
                Text("\(left) left")
                    .font(.footnote)
                    .monospacedDigit()
            }
            .foregroundStyle(Color.white.opacity(0.65))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ForEach(items) { item in
                let checked = store.isChecked(item)
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 0.5)
                Button {
                    store.toggle(item)
                } label: {
                    HStack(spacing: 12) {
                        AskCheckCircle(isOn: checked, size: 24, ring: Color.white.opacity(0.35))
                        Text(item.name)
                            .font(.system(size: 17))
                            .strikethrough(checked)
                            .foregroundStyle(checked ? Color.white.opacity(0.45) : Color.white)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.quantity)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.55))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(checked ? "Checked" : "Not checked")
                .accessibilityHint("Double-tap to \(checked ? "uncheck" : "check off")")
            }
        }
        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.name) on the list")
    }
}
