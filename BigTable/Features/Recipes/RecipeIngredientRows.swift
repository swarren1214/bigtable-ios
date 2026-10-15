import Foundation
import SwiftUI
import UIKit

/// The editor's Ingredients section: one row per ingredient (amount, measurement, name), with
/// add, swipe to delete, drag to reorder, and paste a whole list at once.
struct RecipeIngredientSection: View {
    @Bindable var model: RecipeEditorModel
    @Binding var editMode: EditMode
    var onPaste: () -> Void

    var body: some View {
        Section {
            ForEach($model.ingredients) { $row in
                RecipeIngredientRowEditor(row: $row)
            }
            .onDelete { offsets in
                model.ingredients.remove(atOffsets: offsets)
                model.ensureRows()
            }
            .onMove { source, destination in
                model.ingredients.move(fromOffsets: source, toOffset: destination)
            }

            Button {
                model.ingredients.append(RecipeIngredientDraft())
            } label: {
                Label("Add Ingredient", systemImage: "plus.circle.fill")
            }
            Button {
                onPaste()
            } label: {
                Label("Paste a List", systemImage: "list.bullet.clipboard")
            }
        } header: {
            RecipeEditorSectionHeader(title: "Ingredients", editMode: $editMode)
        } footer: {
            if model.hasInvalidAmount {
                Text("Use a decimal (1.5), fraction (1/2), or mixed fraction (1 1/2) for amounts.")
                    .foregroundStyle(.red)
            }
        }
    }
}

/// One ingredient: the amount ("1 1/2"), a measurement menu (cup, tbsp, lb…), and the name.
struct RecipeIngredientRowEditor: View {
    @Binding var row: RecipeIngredientDraft

    private var measurementLabel: String {
        row.measurement.isEmpty ? "unit" : Ingredients.shortLabel(row.measurement)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("1", text: $row.amount)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.center)
                .frame(width: 54)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
                .foregroundStyle(row.amountIsValid ? Color.primary : Color.red)
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
                .font(.subheadline.weight(.medium))
                .foregroundStyle(row.measurement.isEmpty ? Color.secondary : Color.primary)
                .frame(minWidth: 58)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
            }
            .accessibilityLabel("Measurement, \(row.measurement.isEmpty ? "none" : measurementLabel)")

            TextField("Ingredient", text: $row.name)
                .textInputAutocapitalization(.never)
        }
    }
}

/// The editor's Steps section: numbered steps you can type, delete, reorder, or paste.
struct RecipeStepSection: View {
    @Bindable var model: RecipeEditorModel
    @Binding var editMode: EditMode
    var onPaste: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Section {
            ForEach($model.steps) { $step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(number(of: step))")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(accent)
                        .frame(width: 22, alignment: .trailing)
                        .accessibilityHidden(true)
                    TextField("Describe this step", text: $step.text, axis: .vertical)
                        .lineLimit(1...8)
                        .accessibilityLabel("Step \(number(of: step))")
                }
            }
            .onDelete { offsets in
                model.steps.remove(atOffsets: offsets)
                model.ensureRows()
            }
            .onMove { source, destination in
                model.steps.move(fromOffsets: source, toOffset: destination)
            }

            Button {
                model.steps.append(RecipeStepDraft())
            } label: {
                Label("Add Step", systemImage: "plus.circle.fill")
            }
            Button {
                onPaste()
            } label: {
                Label("Paste Steps", systemImage: "list.bullet.clipboard")
            }
        } header: {
            RecipeEditorSectionHeader(title: "Steps", editMode: $editMode)
        }
    }

    private func number(of step: RecipeStepDraft) -> Int {
        (model.steps.firstIndex { $0.id == step.id } ?? 0) + 1
    }
}

/// A section header with Reorder / Done, which turns on drag handles for ingredients and steps.
struct RecipeEditorSectionHeader: View {
    var title: String
    @Binding var editMode: EditMode

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(editMode.isEditing ? "Done" : "Reorder") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
            .font(.footnote.weight(.semibold))
            .textCase(nil)
        }
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
            HStack {
                Text("Tags")
                Spacer()
                NavigationLink("Manage Tags") {
                    ManageTagsView()
                }
                .font(.footnote.weight(.semibold))
                .textCase(nil)
            }
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
