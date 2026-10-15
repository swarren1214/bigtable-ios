import Foundation
import SwiftUI
import UIKit

/// How ingredient amounts read: kitchen fractions (1 ½) or decimals (1.5).
nonisolated enum RecipeAmountStyle: String, CaseIterable, Identifiable, Sendable {
    case fraction, decimal
    var id: String { rawValue }
    var label: String { self == .fraction ? "½" : "0.5" }
    var accessibilityName: String { self == .fraction ? "Fractions" : "Decimals" }
}

/// Publish or unpublish, with the question each asks first.
nonisolated enum RecipePublishAction: Identifiable, Hashable, Sendable {
    case publish, unpublish

    var id: Self { self }
    var title: String { self == .publish ? "Publish recipe?" : "Unpublish recipe?" }
    var message: String {
        self == .publish
            ? "Publishing makes this recipe discoverable to other families on BigTable."
            : "Unpublishing removes this recipe from discovery for new people. Anyone who saved it keeps their copy."
    }
    var button: String { self == .publish ? "Publish" : "Unpublish" }
}

/// A link to share, for the share sheet.
nonisolated struct RecipeShareItem: Identifiable, Sendable {
    var url: URL
    var id: String { url.absoluteString }
}

/// One recipe: its photo, who made it, servings you can scale, the ingredients and numbered
/// steps, and what you can do with it (favorite, like, share, add to the plan, and for your own
/// recipes edit, publish and delete). When you're looking at the version you saved and the
/// creator has published changes since, it offers the latest.
struct RecipeDetailView: View {
    let recipeID: String
    let versionID: String?
    /// Off when pushed onto a stack that has its own Back button.
    var showsCloseButton: Bool

    init(recipeID: String, versionID: String?, showsCloseButton: Bool = true) {
        self.recipeID = recipeID
        self.versionID = versionID
        self.showsCloseButton = showsCloseButton
    }

    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent

    @State private var detail: RecipeDetail?
    @State private var requestedVersionID: String??
    @State private var loadError: String?
    @State private var scaleEnabled = false
    @State private var servings = 1
    @State private var amountStyle: RecipeAmountStyle = .fraction

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var showAddToPlan = false
    @State private var editing: RecipeDetail?
    @State private var confirmDelete = false
    @State private var confirmLifecycle: RecipePublishAction?
    @State private var askEnableVisibility = false
    @State private var askPublishToShare = false
    @State private var shareAfterPublish = false
    @State private var shareItem: RecipeShareItem?
    @State private var likePulse = 0

    private let api = BigTableAPI.shared
    private var library: RecipeLibrary { .shared }

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if let loadError {
                ScrollView {
                    RetryCard(message: loadError) { Task { await load() } }
                        .padding(16)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(detail?.title ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            if detail == nil {
                await load()
            }
        }
        .onChange(of: library.revision) { Task { await load() } }
        .sheet(isPresented: $showAddToPlan) {
            if let detail { RecipeAddToPlanSheet(recipe: detail) }
        }
        .sheet(item: $editing) { recipe in
            RecipeEditorView(mode: .edit(recipe))
        }
        .sheet(item: $shareItem) { item in
            RecipeShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .alert(Text(confirmLifecycle?.title ?? ""), isPresented: isPresented($confirmLifecycle), presenting: confirmLifecycle) { action in
            Button("Cancel", role: .cancel) {}
            Button(action.button, role: action == .unpublish ? .destructive : nil) {
                Task { await startLifecycle(action) }
            }
        } message: { action in
            Text(action.message)
        }
        .alert("Show your profile to publish?", isPresented: $askEnableVisibility) {
            Button("Not Now", role: .cancel) { shareAfterPublish = false }
            Button("Show and Publish") { Task { await runLifecycle(.publish, enableVisibility: true) } }
        } message: {
            Text("Published recipes appear on your community profile, so your profile needs to be visible. Turn it on now?")
        }
        .alert("Publish to share?", isPresented: $askPublishToShare) {
            Button("Cancel", role: .cancel) {}
            Button("Publish and Share") {
                shareAfterPublish = true
                Task { await startLifecycle(.publish) }
            }
        } message: {
            Text("Only published recipes can be shared. Publish this recipe and share it?")
        }
        .confirmationDialog("Delete “\(detail?.title ?? "this recipe")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Recipe", role: .destructive) { Task { await deleteRecipe() } }
        } message: {
            Text("If it's in a meal plan or someone saved it, it's kept in Deleted Recipes (in Profile) so you can restore it.")
        }
        .alert("Done", isPresented: isPresented($notice)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        .errorAlert($errorMessage)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ detail: RecipeDetail) -> some View {
        let owned = RecipeFormat.isOwned(createdByProfileId: detail.createdByProfileId, sourceName: detail.sourceName)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Color.clear
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { RecipePhoto(url: detail.imageUrl, cornerRadius: 22, symbolSize: 48) }
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))

                header(detail, owned: owned)

                if detail.hasUpdateAvailable == true, let current = detail.currentVersionId {
                    updateCard(current)
                }

                if detail.status == .removed, owned, AppConfig.publishingEnabled {
                    removedCard(detail)
                }

                if let creatorID = detail.createdByProfileId, !owned, AppConfig.socialEnabled {
                    creatorRow(detail, creatorID: creatorID)
                }

                actions(detail, owned: owned)

                if let text = detail.description?.recipeTrimmed, !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                servingsCard(detail)
                ingredientsSection(detail)
                stepsSection(detail)
                attribution(detail)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
    }

    private func header(_ detail: RecipeDetail, owned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.title)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)

            let facts = RecipeFormat.facts(prepMinutes: detail.prepMinutes, cookMinutes: detail.cookMinutes, baseServings: detail.baseServings, sourceName: detail.sourceName, difficulty: detail.difficulty, likeCount: detail.likeCount)
            if !facts.isEmpty {
                Text(facts)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if owned {
                HStack(spacing: 6) {
                    RecipeLifecycleBadge(status: detail.status ?? .draft)
                    if detail.status == .published, let date = ISODay.timestamp(detail.publishedAt) {
                        TagLabel(text: date.formatted(date: .abbreviated, time: .omitted), color: .secondary)
                    }
                    if let count = detail.versionCount, count > 0 {
                        TagLabel(text: "Version \(count)", color: .secondary)
                    }
                }
            }

            if !detail.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(detail.tags, id: \.self) { tag in
                        TagLabel(text: RecipeQuickFilters.presetLabel(for: tag.lowercased()) ?? tag.uppercased(), color: Color(hex: 0x1E9E6A))
                    }
                }
            }
        }
    }

    private func updateCard(_ currentVersion: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "arrow.triangle.2.circlepath", color: .orange, size: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Update available").font(.headline)
                    Text("You're looking at the version you saved. The creator has published changes since.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("See the Latest") {
                        requestedVersionID = .some(currentVersion)
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func removedCard(_ detail: RecipeDetail) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("This recipe is removed", systemImage: "trash")
                    .font(.headline)
                    .foregroundStyle(Color(hex: 0xD93B30))
                Text("Editing is turned off. Publish it to make it discoverable again, or duplicate it to get a new draft you can edit.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Publish", systemImage: "arrow.up.circle") { confirmLifecycle = .publish }
                    Button("Duplicate", systemImage: "plus.square.on.square") { Task { await duplicate(detail) } }
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
    }

    private func creatorRow(_ detail: RecipeDetail, creatorID: String) -> some View {
        let name = detail.creatorName?.recipeTrimmed.isEmpty == false ? detail.creatorName!.recipeTrimmed : "BigTable creator"
        return Button {
            router.present(.publicProfile(id: creatorID))
        } label: {
            HStack(spacing: 12) {
                MemberAvatar(name: name, color: PersonColor.forKey(creatorID).color, url: detail.creatorAvatarUrl, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Creator")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Creator, \(name)")
        .accessibilityHint("Opens their profile")
    }

    private func actions(_ detail: RecipeDetail, owned: Bool) -> some View {
        let canPlan = model.canManagePlan && detail.status != .removed
        let canLike = detail.status == .published && !owned
        return HStack(spacing: 10) {
            if canPlan {
                Button {
                    showAddToPlan = true
                } label: {
                    Label("Add to Plan", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }

            Button {
                Task { await toggleFavorite(detail) }
            } label: {
                Image(systemName: detail.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(detail.isFavorite ? Color.red : Color.primary)
                    .frame(minWidth: 24)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityLabel(detail.isFavorite ? "Remove from favorites" : "Add to favorites")

            if canLike {
                Button {
                    likePulse += 1
                    Task { await toggleLike(detail) }
                } label: {
                    Label("\(detail.likeCount ?? 0)", systemImage: detail.isLiked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .monospacedDigit()
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .sensoryFeedback(.impact(weight: .light), trigger: likePulse)
                .accessibilityLabel(detail.isLiked == true ? "Unlike, \(detail.likeCount ?? 0) likes" : "Like, \(detail.likeCount ?? 0) likes")
            }

            if detail.status != .removed {
                Button {
                    share(detail, owned: owned)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(minWidth: 24)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityLabel("Share recipe")
            }

            if !canPlan { Spacer(minLength: 0) }
        }
        .disabled(isWorking)
    }

    private func servingsCard(_ detail: RecipeDetail) -> some View {
        let note: String = scaleEnabled
            ? "Amounts for \(servings) servings"
            : "Original amounts, serves \(RecipeFormat.servings(detail.baseServings))"
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $scaleEnabled.animation(.smooth)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scale ingredients").font(.headline)
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if scaleEnabled {
                    Stepper(value: $servings, in: 1...50) {
                        HStack {
                            Text("Servings")
                            Spacer()
                            Text("\(servings)")
                                .font(.headline)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .accessibilityValue("\(servings) servings")
                }
            }
        }
    }

    private func ingredientsSection(_ detail: RecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Ingredients") {
                Picker("Amounts", selection: $amountStyle) {
                    ForEach(RecipeAmountStyle.allCases) { style in
                        Text(style.label)
                            .accessibilityLabel(style.accessibilityName)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
            Card(padding: 0) {
                if detail.ingredients.isEmpty {
                    Text("There's no ingredient list for this recipe yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(detail.ingredients.enumerated()), id: \.element.id) { index, ingredient in
                            let parts = ingredientParts(ingredient, base: detail.baseServings)
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(parts.quantity)
                                    .font(.body.weight(.semibold))
                                    .monospacedDigit()
                                    .frame(minWidth: 70, alignment: .leading)
                                Text(parts.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .accessibilityElement(children: .combine)
                            if index < detail.ingredients.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stepsSection(_ detail: RecipeDetail) -> some View {
        let steps = detail.instructions.map(RecipeFormat.stripStepNumber).filter { !$0.isEmpty }
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Steps")
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(accent, in: Circle())
                                    .accessibilityLabel("Step \(index + 1)")
                                Text(step)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func attribution(_ detail: RecipeDetail) -> some View {
        let text = detail.attributionText?.recipeTrimmed ?? ""
        let link = detail.sourceUrl.flatMap { URL(string: $0) }
        if !text.isEmpty || link != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !text.isEmpty {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let link {
                    Link(destination: link) {
                        Label(link.host() ?? "View the original", systemImage: "safari")
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsCloseButton {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
        if let detail, RecipeFormat.isOwned(createdByProfileId: detail.createdByProfileId, sourceName: detail.sourceName) {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if detail.status != .removed {
                        Button("Edit", systemImage: "pencil") { editing = detail }
                    }
                    if AppConfig.publishingEnabled {
                        if detail.status == .published {
                            Button("Unpublish", systemImage: "arrow.down.circle") { confirmLifecycle = .unpublish }
                        } else {
                            Button("Publish", systemImage: "arrow.up.circle") { confirmLifecycle = .publish }
                        }
                    }
                    Button("Duplicate as Draft", systemImage: "plus.square.on.square") { Task { await duplicate(detail) } }
                    if detail.status != .removed {
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    if isWorking {
                        ProgressView()
                    } else {
                        Label("More", systemImage: "ellipsis")
                    }
                }
                .disabled(isWorking)
            }
        }
    }

    // MARK: Ingredients

    /// The amount (scaled when scaling is on) with its measurement, and the name. Ingredients
    /// imported as one line ("2 cups flour") with no amount are read the way the Expo app did.
    private func ingredientParts(_ ingredient: RecipeIngredient, base: Double) -> (quantity: String, name: String) {
        var amount = ingredient.amount
        var measurement = ingredient.measurementType
        var name = ingredient.name
        if amount == nil {
            let parsed = Ingredients.parseLine(ingredient.name)
            if let parsedAmount = parsed.amount {
                amount = parsedAmount
                measurement = measurement ?? parsed.measurementType
                name = parsed.name.isEmpty ? ingredient.name : parsed.name
            }
        }
        let factor = scaleEnabled && base > 0 ? Double(servings) / base : 1
        let quantity: String
        if let amount {
            let scaled = amount * factor
            quantity = amountStyle == .fraction ? Ingredients.displayAmount(scaled) : Ingredients.formatAmount(scaled)
        } else {
            quantity = ""
        }
        let unit = Ingredients.shortLabel(measurement)
        return ([quantity, unit].filter { !$0.isEmpty }.joined(separator: " "), name)
    }

    // MARK: Loading

    private func load() async {
        let version: String? = requestedVersionID ?? versionID
        do {
            let loaded = try await api.recipe(recipeID, versionId: version)
            if detail == nil || detail?.id != loaded.id || detail?.baseServings != loaded.baseServings {
                servings = min(50, max(1, Int(loaded.baseServings.rounded())))
            }
            detail = loaded
            loadError = nil
        } catch is CancellationError {
            return
        } catch let error as APIError where error.status == 404 {
            loadError = versionID != nil ? "This saved version of the recipe isn't available to you anymore." : "This recipe isn't available to you anymore."
        } catch {
            if detail == nil {
                loadError = error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Actions

    private func toggleFavorite(_ recipe: RecipeDetail) async {
        let next = !recipe.isFavorite
        detail?.isFavorite = next
        do {
            try await library.setFavorite(id: recipe.id, saved: next)
        } catch {
            if detail?.id == recipe.id { detail?.isFavorite = !next }
            errorMessage = error.localizedDescription
        }
    }

    private func toggleLike(_ recipe: RecipeDetail) async {
        let next = !(recipe.isLiked ?? false)
        let previousCount = recipe.likeCount
        detail?.isLiked = next
        detail?.likeCount = max(0, (previousCount ?? 0) + (next ? 1 : -1))
        do {
            try await library.setLike(id: recipe.id, liked: next, previousCount: previousCount)
        } catch {
            if detail?.id == recipe.id {
                detail?.isLiked = recipe.isLiked
                detail?.likeCount = previousCount
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Only published recipes can be shared (as in the Expo app); others offer to publish first.
    private func share(_ recipe: RecipeDetail, owned: Bool) {
        if recipe.status == .published {
            presentShare(recipe)
        } else if owned, AppConfig.publishingEnabled {
            askPublishToShare = true
        } else {
            errorMessage = "Only published recipes can be shared."
        }
    }

    private func presentShare(_ recipe: RecipeDetail) {
        let id = recipe.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? recipe.id
        if let url = URL(string: "https://bigtableapp.com/recipe?id=\(id)") {
            shareItem = RecipeShareItem(url: url)
        }
    }

    /// Publishing needs a visible community profile; ask to turn it on when it's off.
    private func startLifecycle(_ action: RecipePublishAction) async {
        guard action == .publish else {
            await runLifecycle(.unpublish, enableVisibility: false)
            return
        }
        isWorking = true
        let visible = (try? await api.socialVisibility().socialProfileVisible) ?? false
        isWorking = false
        if visible {
            await runLifecycle(.publish, enableVisibility: false)
        } else {
            askEnableVisibility = true
        }
    }

    private func runLifecycle(_ action: RecipePublishAction, enableVisibility: Bool) async {
        guard let recipe = detail else { return }
        let previousStatus = recipe.status
        let previousPublishedAt = recipe.publishedAt
        let nextStatus: RecipeStatus = action == .publish ? .published : .unpublished
        let nextPublishedAt: String? = action == .publish ? Date.now.ISO8601Format() : nil
        isWorking = true
        defer { isWorking = false }
        do {
            if enableVisibility {
                let response = try await api.setSocialVisibility(true)
                guard response.socialProfileVisible else {
                    throw APIError(kind: .rejected, status: 400, message: "Your profile couldn't be made visible, so the recipe wasn't published.")
                }
            }
            detail?.status = nextStatus
            detail?.publishedAt = nextPublishedAt
            library.update(recipe.id) {
                $0.status = nextStatus
                $0.publishedAt = nextPublishedAt
            }
            if action == .publish {
                _ = try await api.publishRecipe(recipe.id)
            } else {
                _ = try await api.unpublishRecipe(recipe.id)
            }
            if let refreshed = try? await api.recipe(recipe.id, versionId: requestedVersionID ?? versionID) {
                detail = refreshed
                library.update(recipe.id) {
                    $0.status = refreshed.status
                    $0.publishedAt = refreshed.publishedAt
                    $0.currentVersionId = refreshed.currentVersionId
                }
            }
            if action == .publish, shareAfterPublish, let current = detail {
                shareAfterPublish = false
                presentShare(current)
            } else if action == .publish, enableVisibility {
                notice = "Your profile is now visible and your recipe is published."
            }
        } catch {
            shareAfterPublish = false
            if detail?.id == recipe.id {
                detail?.status = previousStatus
                detail?.publishedAt = previousPublishedAt
            }
            library.update(recipe.id) {
                $0.status = previousStatus
                $0.publishedAt = previousPublishedAt
            }
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRecipe() async {
        guard let recipe = detail else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.deleteRecipe(recipe.id)
            library.remove(recipe.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A new draft with the same contents, as the Expo app's Duplicate did (it needs a photo).
    private func duplicate(_ recipe: RecipeDetail) async {
        guard let imageUrl = recipe.imageUrl, !imageUrl.recipeTrimmed.isEmpty else {
            errorMessage = "A recipe needs a photo to be duplicated."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let payload = RecipePayload(
                title: "\(recipe.title) (Copy)",
                imageUrl: imageUrl,
                description: recipe.description,
                prepMinutes: recipe.prepMinutes,
                cookMinutes: recipe.cookMinutes,
                baseServings: recipe.baseServings,
                difficulty: recipe.difficulty,
                tags: recipe.tags,
                ingredients: recipe.ingredients.map(\.input),
                instructions: recipe.instructions.map(RecipeFormat.stripStepNumber)
            )
            _ = try await api.createRecipe(payload)
            library.changed()
            notice = "A draft copy of “\(recipe.title)” is in My Recipes."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

/// The system share sheet, for a recipe's link.
struct RecipeShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
