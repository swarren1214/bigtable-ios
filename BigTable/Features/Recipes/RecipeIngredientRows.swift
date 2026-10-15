import Foundation
import SwiftUI
import UIKit

/// The editor's Ingredients: one row per ingredient (a tinted amount, a measurement and the
/// name), swipe to delete, drag to reorder, and a line at the bottom that takes an ingredient
/// typed however you like ("2 cups beef broth") and splits it up on the device. Paste a List
/// adds many at once.
struct RecipeIngredientSection: View {
    @Bindable var model: RecipeEditorModel
    @Binding var editMode: EditMode
    var onPaste: () -> Void

    @Environment(\.accent) private var accent
    @State private var newLine = ""
    @FocusState private var newLineFocused: Bool

    var body: some View {
        Section {
            ForEach($model.ingredients) { $row in
                RecipeIngredientRowEditor(row: $row)
            }
            .onDelete { offsets in
                model.ingredients.remove(atOffsets: offsets)
            }
            .onMove { source, destination in
                model.ingredients.move(fromOffsets: source, toOffset: destination)
            }

            HStack(spacing: 10) {
                Button {
                    add()
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(accent)
                        .frame(width: 30, height: 30)
                        .background(accent.opacity(0.14), in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add ingredient")
                TextField("Add one, like “2 cups beef broth”", text: $newLine)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .focused($newLineFocused)
                    .onSubmit {
                        add()
                        newLineFocused = true
                    }
                    .accessibilityLabel("New ingredient")
            }
        } header: {
            RecipeEditorSectionHeader(title: "Ingredients", editMode: $editMode, onPaste: onPaste)
        } footer: {
            if model.hasInvalidAmount {
                Text("Use a decimal (1.5), fraction (1/2), or mixed fraction (1 1/2) for amounts.")
                    .foregroundStyle(.red)
            } else {
                Text("Type it however you like. Amounts and measurements are split out for scaling and the grocery list.")
            }
        }
    }

    private func add() {
        guard !newLine.recipeTrimmed.isEmpty else { return }
        model.appendIngredients(from: newLine)
        newLine = ""
    }
}

/// One ingredient: the amount ("1 1/2") in a tinted pill, a measurement menu (cup, tbsp,
/// lb…), and the name.
struct RecipeIngredientRowEditor: View {
    @Binding var row: RecipeIngredientDraft
    @Environment(\.accent) private var accent

    private var measurementLabel: String {
        row.measurement.isEmpty ? "unit" : Ingredients.shortLabel(row.measurement)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("1", text: $row.amount)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.center)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(width: 54)
                .padding(.vertical, 6)
                .background((row.amountIsValid ? accent : Color.red).opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
                .foregroundStyle(row.amountIsValid ? accent : Color.red)
                .accessibilityLabel("Amount")

            Menu {
                Picker("Measurement", selection: $row.measurement) {
                    ForEach(Ingredients.measurements) { option in
                        Text(option.value.isEmpty ? "None" : option.label).tag(option.value)
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(measurementLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(row.measurement.isEmpty ? Color.secondary : accent)
                .frame(minWidth: 54)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(accent.opacity(row.measurement.isEmpty ? 0.05 : 0.08), in: .rect(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Measurement, \(row.measurement.isEmpty ? "none" : measurementLabel)")

            TextField("Ingredient", text: $row.name, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
        }
    }
}

/// The editor's Steps: numbered steps you can type, delete, reorder or paste, and a line at the
/// bottom for the next one.
struct RecipeStepSection: View {
    @Bindable var model: RecipeEditorModel
    @Binding var editMode: EditMode
    var onPaste: () -> Void
    @Environment(\.accent) private var accent
    @State private var newStep = ""
    @FocusState private var newStepFocused: Bool

    var body: some View {
        Section {
            ForEach($model.steps) { $step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    number("\(number(of: step))", filled: true)
                    TextField("Describe this step", text: $step.text, axis: .vertical)
                        .lineLimit(1...10)
                        .accessibilityLabel("Step \(number(of: step))")
                }
                .padding(.vertical, 2)
            }
            .onDelete { offsets in
                model.steps.remove(atOffsets: offsets)
            }
            .onMove { source, destination in
                model.steps.move(fromOffsets: source, toOffset: destination)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                number("\(model.steps.count + 1)", filled: false)
                TextField("What happens next?", text: $newStep, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($newStepFocused)
                    .onChange(of: newStep) {
                        // Return adds the step (the field is multi-line so long steps wrap).
                        guard newStep.contains("\n") else { return }
                        add()
                        newStepFocused = true
                    }
                    .accessibilityLabel("Next step")
            }
            .padding(.vertical, 2)
        } header: {
            RecipeEditorSectionHeader(title: "Steps", editMode: $editMode, onPaste: onPaste)
        }
    }

    private func number(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(filled ? Color.white : accent)
            .frame(width: 26, height: 26)
            .background(filled ? accent : accent.opacity(0.14), in: Circle())
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            .accessibilityHidden(true)
    }

    private func add() {
        let text = newStep.replacingOccurrences(of: "\n", with: " ").recipeTrimmed
        newStep = ""
        guard !text.isEmpty else { return }
        model.appendSteps(from: text)
    }

    private func number(of step: RecipeStepDraft) -> Int {
        (model.steps.firstIndex { $0.id == step.id } ?? 0) + 1
    }
}

/// A section header: the title, then Paste (a whole list at once) and Reorder / Done, which
/// turns on drag handles.
struct RecipeEditorSectionHeader: View {
    var title: String
    @Binding var editMode: EditMode
    var onPaste: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Spacer()
            if let onPaste, !editMode.isEditing {
                Button("Paste a List", action: onPaste)
            }
            Button(editMode.isEditing ? "Done" : "Reorder") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
        .padding(.leading, -4)
    }
}

/// What a paste sheet adds to.
nonisolated enum RecipePasteTarget: String, Identifiable, Sendable {
    case ingredients, steps
    var id: String { rawValue }

    var title: String { self == .ingredients ? "Paste Ingredients" : "Paste Steps" }
    var message: String {
        self == .ingredients
            ? "One ingredient per line, like “2 1/2 lb chicken thighs” or “3 eggs”."
            : "One step per line. Numbers like “1.” are removed."
    }
}

/// Paste a whole ingredient list or set of steps; each line becomes a row.
struct RecipeBulkPasteSheet: View {
    var title: String
    var message: String
    var onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste or type here", text: $text, axis: .vertical)
                        .lineLimit(8...20)
                } footer: {
                    Text(message)
                }
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        text = strings.joined(separator: "\n")
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark") {
                        onAdd(text)
                        dismiss()
                    }
                    .disabled(text.recipeTrimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The editor's tags: your own tags first, then the presets, any other tags the recipe already
/// has, and + to create a tag. Manage Tags renames and deletes yours.
struct RecipeTagSection: View {
    @Bindable var model: RecipeEditorModel
    var onNotice: (RecipeEditorNotice) -> Void

    @Environment(\.accent) private var accent
    @State private var isAdding = false
    @State private var newTag = ""
    @State private var isCreating = false
    @FocusState private var newTagFocused: Bool

    private var library: RecipeLibrary { .shared }

    private var customChips: [CustomTag] {
        library.customTags.filter { !RecipeQuickFilters.normalizedTags.contains($0.normalized) }
    }

    /// Tags on the recipe that are neither presets nor saved tags (from an import, say).
    private var otherSelected: [String] {
        let known = RecipeQuickFilters.normalizedTags.union(customChips.map(\.normalized))
        return model.tags.filter { !known.contains($0) }
    }

    var body: some View {
        Section {
            FlowLayout(spacing: 8) {
                Button {
                    isAdding.toggle()
                    newTagFocused = isAdding
                } label: {
                    Image(systemName: isAdding ? "xmark" : "plus")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 36, height: 34)
                        .foregroundStyle(accent)
                        .background(accent.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isAdding ? "Cancel new tag" : "Create a tag")

                ForEach(customChips) { tag in
                    chip(tag.label, normalized: tag.normalized)
                }
                ForEach(otherSelected, id: \.self) { value in
                    chip(value.uppercased(), normalized: value)
                }
                ForEach(RecipeQuickFilters.tags, id: \.self) { tag in
                    chip(tag, normalized: tag.lowercased())
                }
            }
            .padding(.vertical, 4)

            if isAdding {
                HStack {
                    TextField("New tag", text: $newTag)
                        .textInputAutocapitalization(.characters)
                        .focused($newTagFocused)
                        .submitLabel(.done)
                        .onSubmit(createTag)
                        .onChange(of: newTag) {
                            if newTag.count > 30 { newTag = String(newTag.prefix(30)) }
                        }
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Add", action: createTag)
                            .buttonStyle(.borderless)
                            .disabled(newTag.recipeTrimmed.isEmpty)
                    }
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Tags")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
                NavigationLink("Manage Tags") {
                    ManageTagsView()
                }
                .font(.subheadline.weight(.semibold))
            }
            .textCase(nil)
            .padding(.leading, -4)
        }
    }

    private func chip(_ label: String, normalized: String) -> some View {
        let isOn = model.isTagSelected(normalized)
        return Button {
            model.toggleTag(normalized)
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func createTag() {
        let label = newTag
        guard !label.recipeTrimmed.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            let notice = await model.addCustomTag(label)
            isCreating = false
            newTag = ""
            isAdding = false
            if let notice { onNotice(notice) }
        }
    }
}
