import Combine
import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// New Recipe and Edit Recipe. A new recipe starts on "What are we making?" (describe it, ask
/// for one, paste a link, scan a page or a photo, or write it yourself); AI's recipe opens
/// ready to change by talking. The editor itself: a photo (taken, picked or made with AI), the
/// name and a line about it, servings and times, difficulty, ingredients, steps and tags, with
/// "Finish It with AI" floating at the bottom. A title, an ingredient, a step and a photo are
/// needed to save. Cancel asks before throwing away changes.
struct RecipeEditorView: View {
    let mode: RecipeEditorMode

    enum Stage { case start, editor }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var appModel
    @Environment(\.accent) private var accent

    @State private var model: RecipeEditorModel
    @State private var stage: Stage
    @State private var showRefine = false
    @State private var editMode: EditMode = .inactive
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var confirmDiscard = false
    @State private var notice: RecipeEditorNotice?
    @State private var importFlow = RecipeImportFlow()
    @State private var pasteTarget: RecipePasteTarget?
    @State private var keyboardUp = false

    init(mode: RecipeEditorMode) {
        self.mode = mode
        _model = State(initialValue: RecipeEditorModel(mode: mode))
        if case .create = mode {
            _stage = State(initialValue: .start)
        } else {
            _stage = State(initialValue: .editor)
        }
    }

    private var isPro: Bool {
        appModel.usage?.isPro == true || Subscriptions.shared.isPro
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .start:
                    RecipeStartView(
                        model: model,
                        flow: importFlow,
                        isPro: isPro,
                        onUpgrade: openPaywall,
                        onNotice: show,
                        onFilled: openRefine,
                        onBlank: { withAnimation(.snappy) { stage = .editor } }
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                case .editor:
                    editor
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .navigationTitle(stage == .start ? "New Recipe" : (model.isEditing ? "Edit Recipe" : "New Recipe"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(isPresented: $showRefine) {
                RecipeRefineView(model: model) { Task { await save() } }
            }
            .interactiveDismissDisabled(model.hasChanges || model.isBusy)
            .onAppear { model.applyTagRenames() }
            .task { await RecipeLibrary.shared.loadCustomTags() }
            .modifier(RecipeImportPresenter(model: model, flow: importFlow, onNotice: show, onFilled: openRefine))
            .sheet(item: $pasteTarget) { target in
                RecipeBulkPasteSheet(title: target.title, message: target.message) { text in
                    switch target {
                    case .ingredients: model.appendIngredients(from: text)
                    case .steps: model.appendSteps(from: text)
                    }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
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

    // MARK: The editor

    private var editor: some View {
        List {
            heroSection
            nameSection
            statsSection
            RecipeIngredientSection(model: model, editMode: $editMode) { pasteTarget = .ingredients }
            RecipeStepSection(model: model, editMode: $editMode) { pasteTarget = .steps }
            RecipeTagSection(model: model, onNotice: show)
            saveSection
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(20)
        .environment(\.editMode, $editMode)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if !keyboardUp, !editMode.isEditing {
                aiButton
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
    }

    private var heroSection: some View {
        Section {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if model.hasPhoto {
                        RecipePhoto(url: model.imageURL, data: model.photoData, cornerRadius: 0, symbolSize: 36)
                    } else {
                        emptyHero
                    }
                }
                .overlay {
                    if model.isGeneratingImage {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.largeTitle)
                                .symbolEffect(.pulse)
                            Text("Making a photo…")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.35))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.hasPhoto, !model.isGeneratingImage {
                        HStack(spacing: 4) {
                            if model.photoIsAI {
                                Button {
                                    generatePhoto()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .frame(width: 36, height: 36)
                                }
                                .accessibilityLabel("Make a different photo")
                            }
                            photoMenu {
                                Image(systemName: "camera")
                                    .frame(width: 36, height: 36)
                            }
                            .accessibilityLabel("Change photo")
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
                        .buttonStyle(.borderless)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(10)
                    }
                }
                .clipped()
                .listRowInsets(EdgeInsets())
        }
    }

    private var emptyHero: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.recipeTile.opacity(0.32), accent.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 16) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Brand.recipeTile)
                    .accessibilityHidden(true)
                if model.showsImageHint {
                    Text("Add a name, an ingredient and a step first, so AI knows what to picture.")
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .transition(.opacity)
                }
                HStack(spacing: 10) {
                    photoMenu {
                        Label("Add Photo", systemImage: "camera")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                    Button {
                        generatePhoto()
                    } label: {
                        Label("Make One", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .disabled(model.isGeneratingImage)
                }
                .foregroundStyle(.primary)
                .buttonStyle(.borderless)
            }
            .animation(.snappy, value: model.showsImageHint)
        }
    }

    private func photoMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            Button("Take Photo", systemImage: "camera") { showCamera = true }
            Button("Choose from Library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            Button("Make One with AI", systemImage: "sparkles") { generatePhoto() }
        } label: {
            label()
        }
        .disabled(model.isGeneratingImage)
    }

    private var nameSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Recipe name", text: $model.title, axis: .vertical)
                    .font(.system(.title, design: .serif, weight: .semibold))
                    .textInputAutocapitalization(.words)
                    .lineLimit(1...3)
                TextField("A line about it (optional)", text: $model.details, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...5)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }
    }

    private var statsSection: some View {
        Section {
            HStack(spacing: 10) {
                servesTile
                minutesTile("PREP", text: $model.prepText)
                minutesTile("COOK", text: $model.cookText)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)

            HStack(spacing: 8) {
                ForEach(RecipeEditorModel.difficulties, id: \.self) { level in
                    let isOn = model.difficulty == level
                    Button {
                        withAnimation(.snappy) { model.difficulty = isOn ? "" : level }
                    } label: {
                        Text(level.capitalized)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(isOn ? accent : Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("How hard is it?")
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
        }
    }

    private var servesTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SERVES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(model.servings)")
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(model.servings)))
            HStack(spacing: 6) {
                stepButton("minus", label: "Fewer servings") {
                    model.servings = max(RecipeEditorModel.servingsRange.lowerBound, model.servings - 1)
                }
                .disabled(model.servings <= RecipeEditorModel.servingsRange.lowerBound)
                stepButton("plus", label: "More servings") {
                    model.servings = min(RecipeEditorModel.servingsRange.upperBound, model.servings + 1)
                }
                .disabled(model.servings >= RecipeEditorModel.servingsRange.upperBound)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 26)
                .background(accent.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.borderless)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }

    private func minutesTile(_ title: String, text: Binding<String>) -> some View {
        let minutes = Int(text.wrappedValue) ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                TextField("–", text: text)
                    .keyboardType(.numberPad)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .onChange(of: text.wrappedValue) {
                        let digits = String(text.wrappedValue.filter(\.isNumber).prefix(4))
                        if digits != text.wrappedValue { text.wrappedValue = digits }
                    }
                    .accessibilityLabel("\(title.capitalized) minutes")
                Text("min")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Text(minutes >= 60 ? RecipeRefineView.duration(minutes) : (minutes > 0 ? "minutes" : "Tap to set"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var saveSection: some View {
        let missing = model.missingForSave
        Section {
            if !missing.isEmpty {
                Text("To save, add \(Self.list(missing)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            // Room for the floating AI button.
            Color.clear
                .frame(height: 44)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private var aiButton: some View {
        Button {
            openRefine()
        } label: {
            Label(model.isEditing || model.madeWithAI ? "Change It with AI" : "Finish It with AI", systemImage: "sparkles")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 22)
                .frame(height: 50)
        }
        .buttonStyle(.glassProminent)
        .tint(accent)
        .disabled(model.isBusy)
        .padding(.bottom, 6)
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
        if stage == .editor {
            ToolbarItem(placement: .confirmationAction) {
                if model.isSaving {
                    ProgressView()
                } else {
                    Button("Save", systemImage: "checkmark") { Task { await save() } }
                        .disabled(!model.canSave)
                }
            }
        }
    }

    // MARK: Actions

    private func show(_ notice: RecipeEditorNotice) {
        self.notice = notice
    }

    /// AI wrote or read in a recipe (or Finish It with AI was tapped): show it, ready to
    /// change by talking.
    private func openRefine() {
        stage = .editor
        showRefine = true
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
                show(.failure(error, title: "Couldn't make a photo"))
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
