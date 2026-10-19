import SwiftUI
import UIKit

/// Tell the Pantry: listens the moment it opens. Each phrase is understood as it's said and
/// shows as a change below ("White rice · 4 lb · was 1 lb"); anything unclear gets one
/// question. Nothing is saved until Save.
struct PantryVoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var kitchen = KitchenStore.shared
    @State private var dictation = RecipeDictation()
    /// What was said before the current listening run (each run restarts the transcript).
    @State private var earlier = ""
    @State private var proposals: [PantryVoiceProposal] = []
    @State private var parsedText = ""
    @State private var parseTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var typed = ""
    @State private var typing = false

    private var said: String {
        [earlier, dictation.transcript].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private var question: PantryVoiceProposal? { proposals.first { $0.question != nil } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    orbRow
                    transcript
                    changes
                    if let question { questionCard(question) }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            controls
        }
        .background(Color(red: 0.043, green: 0.043, blue: 0.047).ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task { await listen() }
        .onDisappear {
            parseTask?.cancel()
            dictation.stop()
        }
        .onChange(of: dictation.transcript) { scheduleParse() }
        .alert("Can't listen right now", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Type Instead") { typing = true }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 2) {
                Text("Tell the Pantry").font(.subheadline.weight(.semibold))
                Text("Heard on your \(DeviceName.current)").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button(typing ? "Talk" : "Type") {
                typing.toggle()
                if typing { dictation.stop() } else { Task { await listen() } }
            }
            .font(.subheadline.weight(.semibold))
            .frame(height: 40)
            .padding(.horizontal, 12)
            .background(.white.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var orbRow: some View {
        HStack(spacing: 18) {
            Button {
                if dictation.isListening { dictation.stop() } else { Task { await listen() } }
            } label: {
                ZStack {
                    if dictation.isListening {
                        Circle()
                            .fill(accent.opacity(0.4))
                            .phaseAnimator([false, true]) { circle, grown in
                                circle.scaleEffect(grown ? 1.5 : 1).opacity(grown ? 0 : 1)
                            } animation: { _ in .easeOut(duration: 1.6) }
                    }
                    Circle()
                        .fill(RadialGradient(colors: [accent.mix(with: .white, by: 0.3), accent, accent.mix(with: .black, by: 0.3)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 2, endRadius: 50))
                        .padding(8)
                        .saturation(dictation.isListening ? 1 : 0.2)
                    Image(systemName: "waveform")
                        .font(.system(size: 28, weight: .semibold))
                }
                .frame(width: 84, height: 84)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dictation.isListening ? "Pause listening" : "Keep listening")
            .sensoryFeedback(.impact, trigger: dictation.isListening)
            VStack(alignment: .leading, spacing: 4) {
                Text(dictation.isListening ? "LISTENING" : (typing ? "TYPING" : "PAUSED"))
                    .font(.footnote.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(dictation.isListening ? accent : .white.opacity(0.5))
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.top, 18)
    }

    private var hint: String {
        if question != nil { return "One question before saving." }
        if proposals.isEmpty { return "Say what you have, what's low, or how full a container is." }
        return "Keep going, in any order. Save when you're done."
    }

    @ViewBuilder
    private var transcript: some View {
        if typing {
            HStack(spacing: 8) {
                TextField("“8 lb black beans, out of syrup”", text: $typed, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(12)
                    .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
                    .onSubmit(sendTyped)
                Button("Add", action: sendTyped)
                    .font(.subheadline.weight(.semibold))
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        if !said.isEmpty {
            Text(highlighted)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    /// What was said, with the understood phrases underlined.
    private var highlighted: AttributedString {
        var text = AttributedString(said)
        for proposal in proposals {
            let phrase = proposal.spoken.phrase
            if let range = text.range(of: phrase, options: .caseInsensitive) {
                text[range].swiftUI.underlineStyle = .single
                text[range].swiftUI.foregroundColor = .white
            }
        }
        return text
    }

    @ViewBuilder
    private var changes: some View {
        let amounts = PantryLedger.amounts(kitchen.pantry)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WHAT CHANGES")
                Spacer()
                Text("\(proposals.count) \(proposals.count == 1 ? "thing" : "things")")
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                if proposals.isEmpty {
                    Text("Changes show here before anything is saved.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                ForEach(proposals) { proposal in
                    let described = kitchen.describe(proposal, amounts: amounts)
                    HStack(spacing: 12) {
                        let place = proposal.placeID.flatMap { id in kitchen.pantry.livePlaces.first { $0.id == id } }
                        Image(systemName: proposal.spoken.kind == .level ? "takeoutbag.and.cup.and.straw" : (place?.kind.symbol ?? "cabinet"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(place?.color ?? Color(hex: 0xE09A2B))
                            .frame(width: 34, height: 34)
                            .background((place?.color ?? Color(hex: 0xE09A2B)).opacity(0.2), in: .rect(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(proposal.name).font(.headline)
                            Text(detail(proposal, place: place)).font(.footnote).foregroundStyle(.white.opacity(0.62))
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(described.change)
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundStyle(proposal.spoken.kind == .out ? Color(hex: 0xFF8A7A) : (described.was == "new" ? Color(hex: 0x3DCB8D) : .white))
                            Text(described.was).font(.caption).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .swipeActions { Button("Remove", role: .destructive) { remove(proposal) } }
                    .contextMenu { Button("Remove", systemImage: "trash", role: .destructive) { remove(proposal) } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 24, style: .continuous))
            .animation(.snappy, value: proposals)
        }
    }

    private func detail(_ proposal: PantryVoiceProposal, place: PantryPlace?) -> String {
        switch proposal.spoken.kind {
        case .out: return "Out · goes on your grocery list"
        case .low: return "Low · goes on your grocery list"
        case .level:
            if let id = proposal.containerID, let capacity = kitchen.pantry.containers[id]?.capacity,
               let itemID = proposal.itemID, let item = kitchen.pantry.items[itemID] {
                return "Holds \(PantryUnits.display(capacity, for: item))"
            }
            return proposal.capacity != nil ? "Holds \(Ingredients.formatAmount(proposal.capacity))\(proposal.capacityUnit.map { " " + $0 } ?? "")" : "New container"
        case .set, .add:
            let where_ = place?.name ?? "Somewhere new"
            return proposal.isNew ? "New · \(where_.lowercased())" : where_
        }
    }

    private func questionCard(_ proposal: PantryVoiceProposal) -> some View {
        let isPlace = proposal.question == .place
        return VStack(alignment: .leading, spacing: 10) {
            Text(isPlace
                 ? "“\(proposal.name) is new. Where do you keep it?”"
                 : "“How much does the \(proposal.name.lowercased()) hold?”")
                .font(.subheadline)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if isPlace {
                        ForEach(kitchen.pantry.livePlaces) { place in
                            chip(place.name) { answer(proposal, placeID: place.id) }
                        }
                    } else {
                        ForEach([("5 lb", 5.0, "lb"), ("10 lb", 10, "lb"), ("25 lb", 25, "lb"), ("4 qt", 4, "qt"), ("1 gal", 1, "gal")], id: \.0) { option in
                            chip(option.0) { answer(proposal, capacity: option.1, unit: option.2) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .background(accent.mix(with: Color(white: 0.11), by: 0.78), in: .rect(cornerRadius: 20, style: .continuous))
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.white.opacity(0.16), in: Capsule())
            .buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if dictation.isListening { dictation.stop() } else { Task { await listen() } }
            } label: {
                Image(systemName: dictation.isListening ? "mic.fill" : "mic.slash.fill")
                    .font(.title3)
                    .foregroundStyle(dictation.isListening ? .white : .black)
                    .frame(width: 54, height: 54)
                    .background(dictation.isListening ? Color.white.opacity(0.12) : .white, in: Circle())
            }
            .accessibilityLabel(dictation.isListening ? "Pause listening" : "Keep listening")
            Button {
                Task { await save() }
            } label: {
                Group {
                    if isSaving { ProgressView().tint(.white) } else { Text(proposals.isEmpty ? "Done" : "Save \(proposals.count) Change\(proposals.count == 1 ? "" : "s")") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(accent.opacity(question == nil ? 1 : 0.5), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(question != nil || isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    // MARK: Actions

    private func listen() async {
        guard !typing, !dictation.isListening else { return }
        if !dictation.transcript.isEmpty {
            earlier = said
        }
        do {
            try await dictation.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Parses a moment after the words stop changing.
    private func scheduleParse() {
        parseTask?.cancel()
        parseTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await parse(said)
        }
    }

    private func sendTyped() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        earlier = [earlier, text].filter { !$0.isEmpty }.joined(separator: ". ")
        typed = ""
        Task { await parse(said) }
    }

    private func parse(_ text: String) async {
        guard text != parsedText, !text.isEmpty else { return }
        parsedText = text
        let pantry = kitchen.pantry
        let spoken = await PantryVoiceParser.parse(text, itemNames: pantry.liveItems.map(\.name), containerNames: pantry.liveContainers.map(\.name))
        guard !Task.isCancelled else { return }
        // Keep answers already given for the same phrase.
        let fresh = kitchen.proposals(for: spoken).map { proposal -> PantryVoiceProposal in
            if let old = proposals.first(where: { $0.spoken.phrase == proposal.spoken.phrase && $0.spoken.name == proposal.spoken.name }) {
                var kept = proposal
                kept.id = old.id
                kept.placeID = old.question == nil ? (old.placeID ?? proposal.placeID) : proposal.placeID
                kept.capacity = old.capacity
                kept.capacityUnit = old.capacityUnit
                kept.question = old.question == nil && proposal.question != nil && (old.placeID != nil || old.capacity != nil) ? nil : proposal.question
                return kept
            }
            return proposal
        }
        withAnimation(.snappy) { proposals = fresh }
    }

    private func answer(_ proposal: PantryVoiceProposal, placeID: String? = nil, capacity: Double? = nil, unit: String? = nil) {
        guard let index = proposals.firstIndex(where: { $0.id == proposal.id }) else { return }
        if let placeID { proposals[index].placeID = placeID }
        if let capacity {
            proposals[index].capacity = capacity
            proposals[index].capacityUnit = unit
        }
        withAnimation(.snappy) { proposals[index].question = nil }
    }

    private func remove(_ proposal: PantryVoiceProposal) {
        withAnimation(.snappy) { proposals.removeAll { $0.id == proposal.id } }
    }

    private func save() async {
        dictation.stop()
        parseTask?.cancel()
        guard !proposals.isEmpty else {
            dismiss()
            return
        }
        isSaving = true
        await kitchen.applyVoice(proposals)
        isSaving = false
        dismiss()
    }
}
