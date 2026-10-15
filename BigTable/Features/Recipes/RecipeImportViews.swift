import Foundation
import PhotosUI
import SwiftUI
import UIKit
import VisionKit

/// Which import screen is up (Create with AI, a link, the scanner), and the photo being
/// imported. Lives with the editor so the sheets sit outside the form's lazy rows.
@MainActor
@Observable
final class RecipeImportFlow {
    var showAICreate = false
    var showLinkImport = false
    var showScanner = false
    var showScanCamera = false
    var photoItem: PhotosPickerItem?
}

/// The top of the recipe form: start from what you say or type (AI fills in the recipe), or
/// with Pro, from a scanned cookbook page, a photo or screenshot, or a link.
struct RecipeImportSection: View {
    var model: RecipeEditorModel
    @Bindable var flow: RecipeImportFlow
    var isPro: Bool
    var onUpgrade: () -> Void

    private var isBusy: Bool { model.isBusy }

    var body: some View {
        Section {
            Button {
                flow.showAICreate = true
            } label: {
                RecipeImportRowLabel(symbol: "waveform", color: Color(hex: 0xD9472B), title: "Say or Type It", detail: "Describe the recipe and AI fills in the rest")
            }
            .disabled(isBusy)

            if isPro {
                Button {
                    if VNDocumentCameraViewController.isSupported {
                        flow.showScanner = true
                    } else {
                        flow.showScanCamera = true
                    }
                } label: {
                    RecipeImportRowLabel(symbol: "doc.viewfinder", color: Color(hex: 0x2F6FE0), title: "Scan a Page", detail: "A cookbook page or recipe card, one or more pages")
                }
                .disabled(isBusy)

                PhotosPicker(selection: $flow.photoItem, matching: .images) {
                    RecipeImportRowLabel(symbol: "photo.on.rectangle", color: Color(hex: 0x1E9E54), title: "From a Photo", detail: "A photo or screenshot of a recipe")
                }
                .disabled(isBusy)

                Button {
                    flow.showLinkImport = true
                } label: {
                    RecipeImportRowLabel(symbol: "link", color: Color(hex: 0xE8621A), title: "From a Link", detail: "Paste a link to a recipe online")
                }
                .disabled(isBusy)
            } else {
                Button(action: onUpgrade) {
                    RecipeImportRowLabel(symbol: "doc.viewfinder", color: Color(hex: 0x2F6FE0), title: "Scan, Photo or Link", detail: "Fill in the title, ingredients and steps from a page, a screenshot or a website", showsPro: true)
                }
            }

            if model.isScanning || model.isImportingLink {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(model.isImportingLink ? "Reading the recipe from that link…" : "Reading the recipe…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Start From")
        }
    }
}

/// Presents the import screens for the editor's form, and runs scans of the pages or photo
/// they return.
struct RecipeImportPresenter: ViewModifier {
    var model: RecipeEditorModel
    @Bindable var flow: RecipeImportFlow
    var onNotice: (RecipeEditorNotice) -> Void
    var onUpgrade: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.showAICreate) {
                RecipeAICreateSheet(model: model, onUpgrade: onUpgrade)
            }
            .sheet(isPresented: $flow.showLinkImport) {
                RecipeLinkImportSheet(model: model, onUpgrade: onUpgrade)
            }
            .fullScreenCover(isPresented: $flow.showScanner) {
                RecipeDocumentScanner { images in
                    flow.showScanner = false
                    scan(images)
                } onCancel: {
                    flow.showScanner = false
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $flow.showScanCamera) {
                CameraPicker { image in
                    scan([image])
                }
                .ignoresSafeArea()
            }
            .onChange(of: flow.photoItem) {
                guard let item = flow.photoItem else { return }
                flow.photoItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                        onNotice(RecipeEditorNotice(title: "Couldn't open that photo", message: "Try a different photo or screenshot."))
                        return
                    }
                    scan([image])
                }
            }
    }

    private func scan(_ images: [UIImage]) {
        let jpegs = RecipeScanImages.build(from: images)
        guard !jpegs.isEmpty else {
            onNotice(RecipeEditorNotice(title: "Couldn't read that image", message: "Try again with a clearer photo."))
            return
        }
        Task {
            do {
                let outcome = try await model.scan(jpegs)
                switch outcome {
                case .filled:
                    break
                case .notRecipe(let reason):
                    onNotice(RecipeEditorNotice(title: "No recipe found", message: reason))
                case .nothingFound:
                    onNotice(RecipeEditorNotice(title: "No recipe found", message: "Try again with better light and the whole recipe in view."))
                }
            } catch {
                onNotice(.failure(error, title: "Couldn't read the recipe"))
            }
        }
    }
}

/// A row in Start From: a tinted icon, what it does, and a line about it.
struct RecipeImportRowLabel: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String
    var showsPro = false

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if showsPro { ProBadge() }
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

/// Create with AI: record yourself describing the recipe (the recording is sent to AI), or
/// type or dictate a description. AI fills in the title, description, servings, tags,
/// ingredients and steps.
struct RecipeAICreateSheet: View {
    var model: RecipeEditorModel
    var onUpgrade: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case record, type
        var id: String { rawValue }
        var label: String { self == .record ? "Record" : "Type" }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var mode: Mode = .record
    @State private var recorder = RecipeAudioRecorder()
    @State private var dictation = RecipeDictation()
    @State private var text = ""
    @State private var textBeforeDictation = ""
    @State private var notice: RecipeEditorNotice?
    @FocusState private var textFocused: Bool

    private var canSend: Bool {
        guard !model.isCreatingWithAI else { return false }
        switch mode {
        case .record: return recorder.state != .idle
        case .type: return !text.recipeTrimmed.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("How", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                switch mode {
                case .record:
                    Section {
                        recordPanel
                    } footer: {
                        Text("Tap record and describe the recipe: what's in it, how much, and how you make it. Tap stop, then the check to send.")
                    }
                case .type:
                    Section {
                        TextField("Describe your recipe…", text: $text, axis: .vertical)
                            .lineLimit(6...16)
                            .focused($textFocused)
                        Button {
                            toggleDictation()
                        } label: {
                            Label(dictation.isListening ? "Stop Dictating" : "Dictate", systemImage: dictation.isListening ? "stop.circle.fill" : "mic.fill")
                                .foregroundStyle(dictation.isListening ? Color.red : accent)
                        }
                    } footer: {
                        Text("Type or dictate the recipe, then tap the check. Dictation happens on your \(DeviceName.current) when it can.")
                    }
                }

                if model.isCreatingWithAI {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Writing your recipe…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Create with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        recorder.discard()
                        dictation.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isCreatingWithAI {
                        ProgressView()
                    } else {
                        Button("Send", systemImage: "checkmark") { Task { await send() } }
                            .disabled(!canSend)
                    }
                }
            }
            .interactiveDismissDisabled(model.isCreatingWithAI || recorder.state == .recording)
            .onChange(of: mode) {
                if recorder.state == .recording { recorder.stop() }
                if dictation.isListening { dictation.stop() }
            }
            .onChange(of: dictation.transcript) {
                let heard = dictation.transcript
                guard !heard.isEmpty else { return }
                text = textBeforeDictation.isEmpty ? heard : "\(textBeforeDictation) \(heard)"
            }
            .onDisappear {
                if recorder.state == .recording { recorder.discard() }
                dictation.stop()
            }
            .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }), presenting: notice) { notice in
                if notice.offersUpgrade {
                    Button("See Plans") {
                        dismiss()
                        onUpgrade()
                    }
                    Button("Not Now", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { notice in
                Text(notice.message)
            }
        }
    }

    private var recordPanel: some View {
        VStack(spacing: 14) {
            RecipeWaveform(levels: recorder.levels, isLive: recorder.state == .recording, color: recorder.state == .recording ? .red : accent)
                .frame(height: 44)

            HStack {
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(RecipeAudioRecorder.timeText(recorder.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                if recorder.state == .recorded {
                    Button {
                        recorder.discard()
                    } label: {
                        Image(systemName: "trash")
                            .font(.title3)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Delete recording")
                }

                Button {
                    toggleRecording()
                } label: {
                    Image(systemName: recorder.state == .recording ? "stop.fill" : "mic.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.isCreatingWithAI)
                .accessibilityLabel(recorder.state == .recording ? "Stop recording" : (recorder.state == .recorded ? "Record again" : "Start recording"))
                .sensoryFeedback(.impact, trigger: recorder.state)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }

    private var statusText: String {
        switch recorder.state {
        case .idle: "Tap to record"
        case .recording: "Recording"
        case .recorded: "Ready to send"
        }
    }

    private func toggleRecording() {
        if recorder.state == .recording {
            recorder.stop()
            return
        }
        Task {
            do {
                try await recorder.start()
            } catch {
                notice = RecipeEditorNotice(title: "Recording unavailable", message: error.localizedDescription)
            }
        }
    }

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        textBeforeDictation = text.recipeTrimmed
        textFocused = false
        Task {
            do {
                try await dictation.start()
            } catch {
                notice = RecipeEditorNotice(title: "Dictation unavailable", message: error.localizedDescription)
            }
        }
    }

    private func send() async {
        do {
            let outcome: RecipeImportOutcome
            switch mode {
            case .record:
                if recorder.state == .recording { recorder.stop() }
                guard recorder.duration >= 1.2 else {
                    notice = RecipeEditorNotice(title: "Recording too short", message: "Record at least a couple of seconds describing the recipe.")
                    return
                }
                outcome = try await model.createFromAudio(try recorder.audioData())
            case .type:
                dictation.stop()
                guard text.recipeTrimmed.count >= 10 else {
                    notice = RecipeEditorNotice(title: "Description too short", message: "Add a few more details about the recipe before sending.")
                    return
                }
                outcome = try await model.createFromTranscript(text)
            }
            switch outcome {
            case .filled:
                recorder.discard()
                dismiss()
            case .notRecipe(let reason):
                notice = RecipeEditorNotice(title: "No recipe found", message: reason)
            case .nothingFound:
                notice = RecipeEditorNotice(title: "Not enough to go on", message: "AI couldn't find enough recipe details. Add the ingredients and steps and try again.")
            }
        } catch {
            notice = .failure(error, title: "Create with AI didn't work")
        }
    }
}

/// From a Link: paste a recipe's web address and AI reads the title, description, servings,
/// tags, ingredients and steps from the page.
struct RecipeLinkImportSheet: View {
    var model: RecipeEditorModel
    var onUpgrade: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var notice: RecipeEditorNotice?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/recipe", text: $link)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit { Task { await importLink() } }
                    PasteButton(payloadType: URL.self) { urls in
                        if let first = urls.first { link = first.absoluteString }
                    }
                    .labelStyle(.titleAndIcon)
                } footer: {
                    Text("AI pulls the title, description, servings, tags, ingredients and steps from the page.")
                }
                if model.isImportingLink {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading the recipe…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("From a Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isImportingLink {
                        ProgressView()
                    } else {
                        Button("Import", systemImage: "checkmark") { Task { await importLink() } }
                            .disabled(link.recipeTrimmed.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(model.isImportingLink)
            .onAppear { focused = true }
            .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }), presenting: notice) { notice in
                if notice.offersUpgrade {
                    Button("See Plans") {
                        dismiss()
                        onUpgrade()
                    }
                    Button("Not Now", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { notice in
                Text(notice.message)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func importLink() async {
        let value = link.recipeTrimmed
        guard !value.isEmpty, !model.isImportingLink else { return }
        focused = false
        do {
            switch try await model.importLink(value) {
            case .filled:
                dismiss()
            case .notRecipe(let reason):
                notice = RecipeEditorNotice(title: "No recipe found", message: reason)
            case .nothingFound:
                notice = RecipeEditorNotice(title: "No recipe found", message: "We couldn't pull recipe details from that link.")
            }
        } catch {
            notice = .failure(error, title: "Import didn't work")
        }
    }
}

/// The recording's level meter: bars that scroll as you speak.
struct RecipeWaveform: View {
    var levels: [Double]
    var isLive: Bool
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let barWidth: CGFloat = 3
            let spacing: CGFloat = 2
            let count = max(1, Int(proxy.size.width / (barWidth + spacing)))
            let visible = Array(levels.suffix(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(color.opacity(isLive ? 1 : 0.8))
                        .frame(width: barWidth, height: max(4, CGFloat(level) * proxy.size.height))
                }
                if visible.count < count {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .overlay {
            if levels.isEmpty {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// VisionKit's document camera: scans one or more pages, flattened and cropped.
struct RecipeDocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: RecipeDocumentScanner
        init(_ parent: RecipeDocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}

/// Images for /v1/bigtable/ai/recipe-scan, as the Expo app sent them: each page as a JPEG no larger
/// than 1536 points, and very tall screenshots sliced into bands so the text stays legible.
/// At most 8 images (the API's limit).
enum RecipeScanImages {
    static func build(from images: [UIImage]) -> [Data] {
        var result: [Data] = []
        for image in images {
            result.append(contentsOf: encode(image))
            if result.count >= 8 { break }
        }
        return Array(result.prefix(8))
    }

    private static func encode(_ image: UIImage) -> [Data] {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return [] }
        guard size.height / size.width >= 2.4 else {
            return PhotoTools.jpeg(from: image, maxSide: 1536, quality: 0.82).map { [$0] } ?? []
        }
        // A tall screenshot: up to six bands, each about 1100 wide.
        let targetWidth = min(size.width, 1100)
        let scaledHeight = size.height * targetWidth / size.width
        let bandCount = min(6, max(2, Int((scaledHeight / 1280).rounded(.up))))
        let bandHeight = (size.height / CGFloat(bandCount)).rounded(.up)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var bands: [Data] = []
        for index in 0..<bandCount {
            let originY = CGFloat(index) * bandHeight
            guard originY < size.height else { break }
            let height = min(bandHeight, size.height - originY)
            let scale = targetWidth / size.width
            let outSize = CGSize(width: targetWidth, height: (height * scale).rounded())
            let band = UIGraphicsImageRenderer(size: outSize, format: format).image { _ in
                image.draw(in: CGRect(x: 0, y: -originY * scale, width: targetWidth, height: size.height * scale))
            }
            if let data = band.jpegData(compressionQuality: 0.82) { bands.append(data) }
        }
        return bands
    }
}

/// Recipe photos are square, 1280 points, as the Expo app cropped them.
enum RecipePhotoCrop {
    static func square(_ image: UIImage, side: CGFloat = 1280, quality: CGFloat = 0.86) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let crop = min(size.width, size.height)
        let target = min(side, crop)
        let scale = target / crop
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: (target - drawSize.width) / 2, y: (target - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
