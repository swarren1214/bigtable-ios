import Foundation
import SwiftUI

/// Change the recipe by talking: say or type what to change ("make it dairy-free and enough
/// for 12"), and the recipe above shows what's new, changed or removed, with Undo. Claude makes
/// the change (through the API); your words are heard on the phone. The mic starts listening
/// the moment it's tapped, and sends when you stop talking.
struct RecipeRefineView: View {
    @Bindable var model: RecipeEditorModel
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var request = ""
    @State private var dictation = RecipeDictation()
    @State private var silence: Task<Void, Never>?
    @State private var notice: RecipeEditorNotice?
    @State private var replied = 0
    @FocusState private var focused: Bool

    private static let added = Color(hex: 0x1E9E6A)
    private static let changed = Color(hex: 0xC77700)
    private static let removed = Color(hex: 0xD93B30)

    private var turns: [RecipeRefineTurn] { model.refineTurns }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard
                ingredientsCard
                stepsList
            }
            .padding(16)
            .animation(.snappy, value: turns.count)
        }
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(model.isEditing ? "Edit Recipe" : "New Recipe")
                        .font(.headline)
                    Text(versionLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.isSaving {
                    ProgressView()
                } else if model.canSave {
                    SheetDoneButton("Save", action: onSave)
                } else {
                    SheetDoneButton { dismiss() }
                        .disabled(model.isRefining)
                }
            }
        }
        .onChange(of: dictation.transcript) { heardSomething() }
        .onDisappear {
            silence?.cancel()
            dictation.stop()
        }
        .sensoryFeedback(.success, trigger: replied)
        .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }), presenting: notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    private var versionLine: String {
        let draft = "draft \(turns.count + 1)"
        if model.madeWithAI { return "Made with AI · \(draft)" }
        return turns.isEmpty ? "Change it by talking" : draft.capitalized
    }

    // MARK: The recipe

    private var summaryCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Color.clear
                .frame(width: 84, height: 84)
                .overlay {
                    if model.hasPhoto {
                        RecipePhoto(url: model.imageURL, data: model.photoData, cornerRadius: 18, symbolSize: 22)
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Brand.recipeTile.opacity(0.18))
                            .overlay {
                                if model.isGeneratingImage {
                                    ProgressView()
                                } else {
                                    Image(systemName: "fork.knife")
                                        .font(.title2)
                                        .foregroundStyle(Brand.recipeTile)
                                }
                            }
                    }
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.title.recipeTrimmed.isEmpty ? "Untitled Recipe" : model.title)
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(model.title.recipeTrimmed.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !model.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(model.tags.prefix(4), id: \.self) { tag in
                            Text(RecipeQuickFilters.presetLabel(for: tag) ?? tag.capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 22)
                                .background(accent.opacity(0.12), in: Capsule())
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "Serves 12 · 15 min prep · 4 hr".
    private var metaLine: String {
        var parts = ["Serves \(model.servings)"]
        let prep = Int(model.prepText) ?? 0
        let cook = Int(model.cookText) ?? 0
        if prep > 0, cook > 0 {
            parts.append("\(Self.duration(prep)) prep")
            parts.append(Self.duration(cook))
        } else if prep + cook > 0 {
            parts.append(Self.duration(prep + cook))
        }
        if !model.difficulty.isEmpty { parts.append(model.difficulty.capitalized) }
        return parts.joined(separator: " · ")
    }

    static func duration(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    private var ingredientsCard: some View {
        let rows = model.ingredientChanges
        let changes = rows.filter { $0.kind != .same }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ingredients")
                    .font(.title3.weight(.bold))
                Spacer()
                Text(model.refineBaseline == nil ? (model.madeWithAI ? "From what you described" : "\(rows.count) items") : (changes == 1 ? "1 change" : "\(changes) changes"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("No ingredients yet. Tell AI what you're making.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        ingredientRow(row)
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
                .clipShape(.rect(cornerRadius: 22, style: .continuous))
            }
        }
    }

    private func ingredientRow(_ row: RecipeIngredientChange) -> some View {
        let isRemoved = row.kind == .removed
        let color: Color? = switch row.kind {
        case .new: Self.added
        case .changed: Self.changed
        case .removed: Self.removed
        case .same: nil
        }
        let badge: String? = switch row.kind {
        case .new: "New"
        case .changed: "Changed"
        case .removed: "Removed"
        case .same: nil
        }
        let was = row.was.map { "  was \($0)" } ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.amount.isEmpty ? "–" : row.amount)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isRemoved ? Color.secondary : accent)
                .strikethrough(isRemoved)
                .frame(width: 76, alignment: .leading)
            Text("\(Text(row.name).strikethrough(isRemoved))\(Text(was).font(.footnote).foregroundStyle(.secondary))")
                .foregroundStyle(isRemoved ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let badge, let color {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(color.opacity(0.14), in: Capsule())
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isRemoved ? Color.clear : (color?.opacity(0.08) ?? .clear))
        .accessibilityElement(children: .combine)
    }

    private var stepsList: some View {
        let steps = model.steps.filter { !$0.text.recipeTrimmed.isEmpty }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Steps")
                .font(.title3.weight(.bold))
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                let changed = model.stepChanged(at: index)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(accent, in: Circle())
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    Text(step.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(changed ? Self.changed.opacity(0.1) : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
                .overlay {
                    if changed {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Self.changed.opacity(0.35), lineWidth: 1)
                    }
                }
            }
            if steps.isEmpty {
                Text("No steps yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The conversation

    private var dock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let last = turns.last {
                VStack(alignment: .leading, spacing: 8) {
                    Text(last.request)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(accent, in: .rect(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    HStack(alignment: .top, spacing: 10) {
                        Text(last.reply)
                            .font(.subheadline)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Undo", systemImage: "arrow.uturn.backward") {
                            withAnimation(.snappy) { model.undoRefine() }
                        }
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(model.isRefining)
                    }
                }
            } else if !model.isRefining {
                Text(model.draft.hasContent
                     ? "Tell me what to change: servings, ingredients, the method, how spicy. Every change shows above before you save."
                     : "Tell me what you'd like to make, and I'll write the recipe.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if model.isRefining {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Changing the recipe…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else if dictation.isListening {
                RecipeListeningLabel(text: "Listening… I'll send it when you pause")
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { send(suggestion) }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .background(accent.opacity(0.12), in: Capsule())
                            .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .disabled(model.isRefining)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Change anything…", text: $request, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { send(request) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Change the recipe")
                if !request.recipeTrimmed.isEmpty, !dictation.isListening {
                    Button {
                        send(request)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send")
                } else {
                    RecipeMicButton(isListening: dictation.isListening, size: 40) { toggleDictation() }
                }
            }
            .disabled(model.isRefining)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Three things to try next, picked from what's in the recipe.
    private var suggestions: [String] {
        let draft = model.draft
        let asked = Set(turns.map { $0.request.lowercased() })
        guard draft.hasContent else { return Array(RecipeStartView.ideas.prefix(3)) }
        let names = draft.ingredients.map { $0.name.lowercased() }.joined(separator: " ")
        let steps = draft.steps.map { $0.text.lowercased() }.joined(separator: " ")
        func has(_ words: [String], in text: String) -> Bool { words.contains { text.contains($0) } }
        var ideas: [String] = []
        if draft.servings < 10 { ideas.append("Make enough for 12") }
        if !draft.tags.contains("dairy-free"), has(["milk", "cream", "cheese", "butter", "parmesan", "yogurt"], in: names) {
            ideas.append("Make it dairy-free")
        }
        if !draft.tags.contains("gluten-free"), has(["flour", "pasta", "bread", "noodle", "tortilla", "breadcrumb"], in: names) {
            ideas.append("Make it gluten-free")
        }
        if has(["chili", "chile", "jalapeño", "jalapeno", "cayenne", "sriracha", "red pepper flakes", "hot sauce"], in: names) {
            ideas.append("Less spicy for the kids")
        }
        if (Int(draft.cookText) ?? 0) >= 40 || has(["oven", "simmer", "braise"], in: steps) {
            ideas.append("Can it go in the slow cooker?")
        }
        if draft.steps.count >= 6 { ideas.append("Make the steps simpler") }
        ideas.append(contentsOf: ["Add a vegetable side", "Make it freezer-friendly", "Fewer dishes to wash"])
        var seen = Set<String>()
        return ideas.filter { !asked.contains($0.lowercased()) && seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    // MARK: Actions

    private func toggleDictation() {
        if dictation.isListening {
            silence?.cancel()
            dictation.stop()
            send(request)
            return
        }
        request = ""
        focused = false
        Task {
            do {
                try await dictation.start()
            } catch {
                notice = RecipeEditorNotice(title: "Can't listen right now", message: error.localizedDescription)
            }
        }
    }

    /// Words keep coming in while you talk; a pause of a couple of seconds sends them.
    private func heardSomething() {
        let heard = dictation.transcript
        guard dictation.isListening, !heard.isEmpty else { return }
        request = heard
        silence?.cancel()
        silence = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, dictation.isListening, dictation.transcript == heard else { return }
            dictation.stop()
            send(heard)
        }
    }

    private func send(_ text: String) {
        let ask = text.recipeTrimmed
        guard !ask.isEmpty, !model.isRefining else { return }
        silence?.cancel()
        dictation.stop()
        focused = false
        request = ""
        Task {
            do {
                try await model.refine(ask)
                replied += 1
            } catch {
                request = ask
                notice = .failure(error, title: "Couldn't change the recipe")
            }
        }
    }
}
