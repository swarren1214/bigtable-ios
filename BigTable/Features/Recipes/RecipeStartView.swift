import Foundation
import PhotosUI
import SwiftUI
import UIKit
import VisionKit

/// The first page of New Recipe: describe a recipe, ask for one or paste a link in one box
/// (the mic starts listening the moment it's tapped), or bring one in from a scanned page or
/// a photo, or start from a blank recipe. Words are heard on the device and a link is read on
/// the device; the recipe itself is written by Claude through the API. Scanning needs BigTable
/// Pro or Hearth+; without them, three web imports a month are free.
struct RecipeStartView: View {
    var model: RecipeEditorModel
    @Bindable var flow: RecipeImportFlow
    var isPro: Bool
    /// Opens the Hearth paywall for a feature.
    var onUpgrade: (HearthPaywallFeature) -> Void
    var onNotice: (RecipeEditorNotice) -> Void
    /// AI filled in the recipe: show it, ready to change by talking.
    var onFilled: () -> Void
    /// Write It Myself.
    var onBlank: () -> Void

    @Environment(\.accent) private var accent
    @State private var prompt = ""
    @State private var dictation = RecipeDictation()
    @State private var textBeforeDictation = ""
    @State private var imports = WebImportAllowance.shared
    @FocusState private var focused: Bool

    static let ideas = [
        "A dairy-free lasagna for 12",
        "Something with chicken thighs, 30 min",
        "Grandma’s pot roast, serves 12",
        "Sheet-pan tacos for a crowd",
    ]

    private var link: URL? { Self.link(in: prompt) }
    /// Free accounts have used this month's web imports.
    private var importsUsedUp: Bool { !isPro && imports.remaining == 0 }

    static let scanFeature = HearthPaywallFeature("Recipe scanning", detail: "Photograph a cookbook page, a recipe card or a screenshot.", symbol: "doc.viewfinder")
    static let importFeature = HearthPaywallFeature(
        "Unlimited imports from the web",
        detail: "Paste a link from any recipe site, as often as you like. Three a month are free.",
        symbol: "link"
    )
    private var isWorking: Bool { model.isCreatingWithAI || model.isImportingLink || model.isScanning }
    private var canSend: Bool { prompt.recipeTrimmed.count >= 3 && !isWorking }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What are we making?")
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    Text("Describe it, ask for one, or paste a link. BigTable writes the recipe, and you can keep changing it by talking.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                composer
                ideas
                bringIn

                Label("Nothing is saved until you tap Save", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .onChange(of: dictation.transcript) {
            let heard = dictation.transcript
            guard !heard.isEmpty else { return }
            prompt = textBeforeDictation.isEmpty ? heard : "\(textBeforeDictation) \(heard)"
        }
        .onDisappear { dictation.stop() }
    }

    // MARK: The box

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("“Grandma’s pot roast with carrots, serves 12” or a link from any recipe site", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
                .font(.title3)
                .focused($focused)
                .disabled(isWorking)
                .accessibilityLabel("Describe a recipe or paste a link")

            if link != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Recipe link · read on your \(DeviceName.current)", systemImage: "link")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !isPro {
                        Text(importsNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            } else if dictation.isListening {
                RecipeListeningLabel()
            } else if isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(model.isImportingLink ? "Reading the recipe…" : model.isScanning ? "Reading the page…" : "Writing your recipe…")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                RecipeMicButton(isListening: dictation.isListening, size: 40) { toggleDictation() }
                    .disabled(isWorking)
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first?.recipeTrimmed, !first.isEmpty else { return }
                    prompt = first
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .tint(Color(.systemGray))
                .disabled(isWorking)
                Spacer(minLength: 0)
                Button {
                    Task { await send() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: link != nil ? "arrow.down.doc" : "sparkles")
                        Text(link != nil ? "Import" : "Create")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(accent.opacity(canSend ? 1 : 0.45), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(prompt.isEmpty ? Color.primary.opacity(0.06) : accent.opacity(0.55), lineWidth: 1)
        }
        .animation(.snappy, value: link != nil)
        .animation(.snappy, value: dictation.isListening)
    }

    private var ideas: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Self.ideas, id: \.self) { idea in
                    Button {
                        dictation.stop()
                        prompt = idea
                    } label: {
                        Text(idea)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -16)
        .disabled(isWorking)
    }

    // MARK: Bring one in

    private var bringIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OR BRING ONE IN")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    guard isPro else { return onUpgrade(Self.scanFeature) }
                    if VNDocumentCameraViewController.isSupported {
                        flow.showScanner = true
                    } else {
                        flow.showScanCamera = true
                    }
                } label: {
                    tile(symbol: "doc.viewfinder", color: Color(hex: 0x3B82F6), title: "Scan a Page", detail: "Cookbooks and recipe cards")
                }
                .buttonStyle(.plain)

                if isPro {
                    PhotosPicker(selection: $flow.photoItem, matching: .images) {
                        tile(symbol: "photo", color: Color(hex: 0x2FAE6A), title: "Photo or Screenshot", detail: "From your library")
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { onUpgrade(Self.scanFeature) } label: {
                        tile(symbol: "photo", color: Color(hex: 0x2FAE6A), title: "Photo or Screenshot", detail: "From your library")
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(isWorking)

            Button(action: onBlank) {
                HStack(spacing: 12) {
                    Image(systemName: "pencil")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write It Myself")
                            .font(.body.weight(.semibold))
                        Text("Start with a blank recipe")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(12)
                .padding(.trailing, 4)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
        }
    }

    private func tile(symbol: String, color: Color, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 44)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if !isPro {
                ProBadge()
                    .padding(14)
            }
        }
        .contentShape(.rect)
    }

    /// "2 of 3 free imports left this month".
    private var importsNote: String {
        if importsUsedUp {
            return "You've used this month's \(WebImportAllowance.freePerMonth) free imports."
        }
        return "\(imports.remaining) of \(WebImportAllowance.freePerMonth) free imports left this month"
    }

    // MARK: Actions

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        textBeforeDictation = prompt.recipeTrimmed
        focused = false
        Task {
            do {
                try await dictation.start()
            } catch {
                onNotice(RecipeEditorNotice(title: "Can't listen right now", message: FriendlyError.message(error)))
            }
        }
    }

    private func send() async {
        dictation.stop()
        focused = false
        if link != nil, importsUsedUp {
            onUpgrade(Self.importFeature)
            return
        }
        do {
            let outcome: RecipeImportOutcome
            if let link {
                outcome = try await model.importLink(link.absoluteString)
            } else {
                outcome = try await model.createFromTranscript(prompt)
            }
            switch outcome {
            case .filled:
                if link != nil, !isPro { imports.recordImport() }
                onFilled()
            case .notRecipe(let reason):
                onNotice(RecipeEditorNotice(title: "No recipe found", message: reason))
            case .nothingFound:
                onNotice(RecipeEditorNotice(title: "Not enough to go on", message: "Say a little more about the dish: what's in it, or who it's for."))
            }
        } catch {
            onNotice(.failure(error, title: link != nil ? "Couldn't read that link" : "Couldn't write the recipe"))
        }
    }

    /// The text is a single web link ("https://…" or "allrecipes.com/recipe/…").
    static func link(in text: String) -> URL? {
        let trimmed = text.recipeTrimmed
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil ? trimmed : "https://\(trimmed)"
        guard trimmed.range(of: #"^(https?://)?[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let url = URL(string: candidate), url.host() != nil else { return nil }
        return url
    }
}

/// A round mic button that starts listening the moment it's tapped, and pulses red while it
/// listens.
struct RecipeMicButton: View {
    var isListening: Bool
    var size: CGFloat = 40
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isListening ? "stop.fill" : "mic.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(isListening ? Color.white : Color.primary)
                .frame(width: size, height: size)
                .background(isListening ? Color.red : Color(.tertiarySystemFill), in: Circle())
                .background {
                    if isListening {
                        Circle()
                            .fill(Color.red.opacity(0.35))
                            .phaseAnimator([false, true]) { circle, grown in
                                circle
                                    .scaleEffect(grown ? 1.5 : 1)
                                    .opacity(grown ? 0 : 1)
                            } animation: { _ in .easeOut(duration: 1.2) }
                    }
                }
        }
        .buttonStyle(.borderless)
        .sensoryFeedback(.impact, trigger: isListening)
        .accessibilityLabel(isListening ? "Stop listening" : "Say it")
    }
}

/// "Listening…" with a pulsing red dot.
struct RecipeListeningLabel: View {
    var text = "Listening… tap stop when you're done"

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.3]) { dot, value in
                    dot.opacity(value)
                } animation: { _ in .easeInOut(duration: 0.7) }
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
