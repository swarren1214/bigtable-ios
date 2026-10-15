import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// New Recipe and Edit Recipe: start from AI (say it, scan it, a photo or a link) or type it
/// in: the title, a photo (taken, picked or generated with AI), the description, times,
/// servings and difficulty, tags, ingredients and steps. A title, an ingredient, a step and a
/// photo are needed to save. Cancel asks before throwing away changes.
struct RecipeEditorView: View {
    let mode: RecipeEditorMode

    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var appModel
    @Environment(\.accent) private var accent

    @State private var model: RecipeEditorModel
    @State private var editMode: EditMode = .inactive
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var confirmDiscard = false
    @State private var notice: RecipeEditorNotice?
    @State private var importFlow = RecipeImportFlow()
    @State private var pasteTarget: RecipePasteTarget?

    init(mode: RecipeEditorMode) {
        self.mode = mode
        _model = State(initialValue: RecipeEditorModel(mode: mode))
    }

    private var isPro: Bool {
        appModel.usage?.isPro == true || Subscriptions.shared.isPro
    }

    var body: some View {
        NavigationStack {
            Form {
                RecipeImportSection(model: model, flow: importFlow, isPro: isPro, onUpgrade: openPaywall)
                basicsSection
                photoSection
                RecipeTagSection(model: model, onNotice: show)
                RecipeIngredientSection(model: model, editMode: $editMode) { pasteTarget = .ingredients }
                RecipeStepSection(model: model, editMode: $editMode) { pasteTarget = .steps }
                saveSection
            }
            .environment(\.editMode, $editMode)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(model.isEditing ? "Edit Recipe" : "New Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .interactiveDismissDisabled(model.hasChanges || model.isBusy)
            .onAppear { model.applyTagRenames() }
            .task { await RecipeLibrary.shared.loadCustomTags() }
            .modifier(RecipeImportPresenter(model: model, flow: importFlow, onNotice: show, onUpgrade: openPaywall))
            .sheet(item: $pasteTarget) { target in
                RecipeBulkPasteSheet(title: target.title, message: target.message) { text in
                    switch target {
                    case .ingredients: model.appendIngredients(from: text)
                    case .steps: model.appendSteps(from: text)
                    }
                }
            }
            .onChange(of: photoItem) { loadPickedPhoto() }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    if let jpeg = RecipePhotoCrop.square(image) {
                        model.setPhoto(jpeg)
                    }
                }
                .ignoresSafeArea()
            }
            .confirmationDialog("Discard this recipe?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("You have changes that haven't been saved.")
            }
            .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }), presenting: notice) { notice in
                if notice.offersUpgrade {
                    Button("See Plans") { openPaywall() }
                    Button("Not Now", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { notice in
                Text(notice.message)
            }
        }
    }

    // MARK: Sections

    private var basicsSection: some View {
        Section {
            TextField("Title", text: $model.title)
                .font(.headline)
                .textInputAutocapitalization(.words)
            TextField("Description (optional)", text: $model.details, axis: .vertical)
                .lineLimit(2...6)
            Stepper(value: $model.servings, in: RecipeEditorModel.servingsRange) {
                LabeledContent("Serves") {
                    Text("\(model.servings)")
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            LabeledContent("Prep") {
                RecipeMinutesField(text: $model.prepText)
            }
            LabeledContent("Cook") {
                RecipeMinutesField(text: $model.cookText)
            }
            Picker("Difficulty", selection: $model.difficulty) {
                Text("Not set").tag("")
                ForEach(RecipeEditorModel.difficulties, id: \.self) { level in
                    Text(level.capitalized).tag(level)
                }
            }
        } header: {
            Text("Basics")
        }
    }

    private var photoSection: some View {
        Section {
            if model.hasPhoto || model.isGeneratingImage {
                Color.clear
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if model.hasPhoto {
                            RecipePhoto(url: model.imageURL, data: model.photoData, cornerRadius: 14, symbolSize: 36)
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Brand.recipeTile.opacity(0.25))
                        }
                    }
                    .overlay {
                        if model.isGeneratingImage {
                            VStack(spacing: 10) {
                                Image(systemName: "sparkles")
                                    .font(.largeTitle)
                                    .symbolEffect(.pulse)
                                Text("Generating photo…")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.35), in: .rect(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if model.hasPhoto, !model.isGeneratingImage {
                            HStack(spacing: 8) {
                                if model.photoIsAI {
                                    Button {
                                        generatePhoto()
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .frame(width: 36, height: 36)
                                    }
                                    .accessibilityLabel("Generate a different photo")
                                }
                                Button {
                                    model.clearPhoto()
                                } label: {
                                    Image(systemName: "xmark")
                                        .frame(width: 36, height: 36)
                                }
                                .accessibilityLabel("Remove photo")
                            }
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .padding(8)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            if !model.hasPhoto {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                .disabled(model.isGeneratingImage)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }
                .disabled(model.isGeneratingImage)
                Button {
                    generatePhoto()
                } label: {
                    Label("Generate with AI", systemImage: "sparkles")
                }
                .disabled(model.isGeneratingImage)
            }
        } header: {
            Text("Photo")
        } footer: {
            if model.showsImageHint {
                Text("Add a title, an ingredient and a step so AI knows what to picture.")
            } else if !model.hasPhoto, !model.isGeneratingImage {
                Text("Every recipe needs a photo before it's saved.")
            }
        }
    }

    @ViewBuilder
    private var saveSection: some View {
        let missing = model.missingForSave
        if !missing.isEmpty {
            Section {
                Text("To save, add \(Self.list(missing)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark") {
                if model.hasChanges {
                    confirmDiscard = true
                } else {
                    dismiss()
                }
            }
            .disabled(model.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            if model.isSaving {
                ProgressView()
            } else {
                Button("Save", systemImage: "checkmark") { Task { await save() } }
                    .disabled(!model.canSave)
            }
        }
    }

    // MARK: Actions

    private func show(_ notice: RecipeEditorNotice) {
        self.notice = notice
    }

    /// Pro is a sheet of its own: this one closes first (as the Expo app did).
    private func openPaywall() {
        dismiss()
        router.present(.paywall)
    }

    private func generatePhoto() {
        Task {
            do {
                try await model.generateImage()
            } catch {
                show(.failure(error, title: "Couldn't generate a photo"))
            }
        }
    }

    private func loadPickedPhoto() {
        guard let item = photoItem else { return }
        photoItem = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = RecipePhotoCrop.square(image) else {
                show(RecipeEditorNotice(title: "Couldn't use that photo", message: "Try a different photo."))
                return
            }
            model.setPhoto(jpeg)
        }
    }

    private func save() async {
        do {
            _ = try await model.save()
            RecipeLibrary.shared.changed()
            dismiss()
        } catch {
            show(.failure(error, title: "Couldn't save the recipe"))
        }
    }

    /// "a title, a step and a photo".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }
}

/// A minutes field: digits only, with "min" after it.
struct RecipeMinutesField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("0", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 70)
                .onChange(of: text) {
                    let digits = String(text.filter(\.isNumber).prefix(4))
                    if digits != text { text = digits }
                }
            Text("min")
                .foregroundStyle(.secondary)
        }
    }
}
