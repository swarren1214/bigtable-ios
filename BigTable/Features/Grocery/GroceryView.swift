import SwiftUI
import UIKit

/// The Grocery tab: the household's shopping list by aisle. Tap an item to check it off; the
/// header shows the days it covers, how much is left and (with Pro) the cost estimate. The
/// organizer can add, edit and swipe away items, make a list with AI, and restore an older
/// list from History. Everyone can share what's still needed.
struct GroceryView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(Subscriptions.self) private var subscriptions
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accent) private var accent

    @State private var store = GroceryStore()
    @State private var hideChecked = false
    @State private var showGenerate = false
    @State private var showHistory = false
    @State private var showNewSection = false
    @State private var editing: GroceryItemEditTarget?
    @State private var newItemText = ""
    @State private var newItemSection = "Other"
    @FocusState private var addFieldFocused: Bool

    private var isPro: Bool { model.usage?.isPro == true || subscriptions.isPro }
    private var canEdit: Bool { model.isOrganizer }
    /// The snapshot API only lets the organizer save a whole list, so AI lists are theirs to
    /// make (as in the Expo app).
    private var canGenerate: Bool { model.isOrganizer && model.canUseAIGrocery }
    /// Reload when someone else signs in or the household changes (joining or leaving one).
    private var householdKey: String { "\(model.userID ?? "")|\(model.membership?.organizerProfileId ?? "")" }

    var body: some View {
        content
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Grocery")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .bigTableToolbar()
            .task(id: householdKey) { await store.load() }
            .refreshable { await store.load() }
            .onDisappear { Task { await store.flush() } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { Task { await store.flush() } }
            }
            .sheet(isPresented: $showGenerate) {
                GroceryGenerateView(store: store, weekStart: router.weekStart)
            }
            .sheet(isPresented: $showHistory) {
                GroceryHistoryView(store: store)
            }
            .sheet(isPresented: $showNewSection) {
                GroceryNewSectionSheet { name in
                    let added = store.addSection(name)
                    if added { newItemSection = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    return added
                }
            }
            .sheet(item: $editing) { target in
                GroceryItemEditor(target: target, sectionChoices: store.sectionChoices) { name, quantity, bulk, section in
                    store.updateItem(id: target.item.id, name: name, quantity: quantity, bulk: bulk, sectionName: section)
                } onDelete: {
                    store.deleteItem(target.item.id)
                }
            }
            .errorAlert($store.errorMessage)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded, let error = store.loadError {
            ScrollView {
                RetryCard(message: error) { Task { await store.load() } }
                    .padding(16)
            }
        } else if !store.hasLoaded {
            ScrollView {
                LoadingCard(title: "Loading your list…")
                    .padding(16)
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                GroceryHeaderCard(store: store, isPro: isPro) {
                    router.present(.paywall)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if !model.isOrganizer {
                Section {
                    Label("Your household organizer makes the grocery list. You can check items off as you shop.", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }

            if canEdit {
                Section {
                    addRow
                }
            }

            if store.isEmpty {
                Section {
                    emptyState
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            ForEach(visibleSections) { section in
                sectionView(section)
            }

            if hideChecked, store.checkedCount > 0 {
                Section {
                    Button("Show \(store.checkedCount) checked \(store.checkedCount == 1 ? "item" : "items")", systemImage: "eye") {
                        withAnimation { hideChecked = false }
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: BigTableScreen<EmptyView>.readableWidth)
        .frame(maxWidth: .infinity)
        .animation(.smooth, value: hideChecked)
    }

    /// Sections to show: those with items (or, hiding checked items, with items left), plus
    /// empty sections the organizer added so they can fill them.
    private var visibleSections: [GrocerySection] {
        store.orderedSections.compactMap { section in
            if section.items.isEmpty {
                return canEdit && !GroceryStore.defaultSections.contains(section.name) ? section : nil
            }
            guard hideChecked else { return section }
            let remaining = section.items.filter { !store.isChecked($0) }
            guard !remaining.isEmpty else { return nil }
            return GrocerySection(name: section.name, icon: section.icon, items: remaining)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: GrocerySection) -> some View {
        let full = store.sections.first { $0.name == section.name } ?? section
        let color = GroceryAisleStyle.color(section.name)
        Section {
            ForEach(section.items) { item in
                GroceryItemRow(item: item, isChecked: store.isChecked(item), color: color) {
                    store.toggle(item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if canEdit {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            withAnimation { store.deleteItem(item.id) }
                        }
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button(store.isChecked(item) ? "Uncheck" : "Check", systemImage: store.isChecked(item) ? "circle" : "checkmark.circle") {
                        store.toggle(item)
                    }
                    .tint(color)
                }
                .contextMenu {
                    Button(store.isChecked(item) ? "Mark as Needed" : "Check Off", systemImage: store.isChecked(item) ? "circle" : "checkmark.circle") {
                        store.toggle(item)
                    }
                    if canEdit {
                        Button("Edit…", systemImage: "pencil") {
                            editing = GroceryItemEditTarget(item: item, sectionName: section.name)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.deleteItem(item.id)
                        }
                    }
                }
            }
            if canEdit {
                Button {
                    newItemSection = section.name
                    addFieldFocused = true
                } label: {
                    Label("Add to \(section.name)", systemImage: "plus")
                        .font(.subheadline)
                }
                .foregroundStyle(color)
            }
        } header: {
            GrocerySectionHeader(section: full, remaining: full.items.filter { !store.isChecked($0) }.count) { checked in
                withAnimation { store.setSection(full, checked: checked) }
            }
        }
    }

    // MARK: - Adding

    private var addRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            TextField("Add an item", text: $newItemText)
                .focused($addFieldFocused)
                .submitLabel(.done)
                .onSubmit(addItem)
            Menu {
                Picker("Section", selection: $newItemSection) {
                    ForEach(store.sectionChoices, id: \.self) { name in
                        Label(name, systemImage: GroceryAisleStyle.symbol(name)).tag(name)
                    }
                }
                Divider()
                Button("New Section…", systemImage: "folder.badge.plus") { showNewSection = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: GroceryAisleStyle.symbol(newItemSection))
                    Text(newItemSection)
                        .lineLimit(1)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroceryAisleStyle.color(newItemSection))
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(GroceryAisleStyle.color(newItemSection).opacity(0.14), in: Capsule())
            }
            .accessibilityLabel("Section: \(newItemSection)")
            if !newItemText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Add", action: addItem)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .frame(minHeight: 44)
    }

    /// "2 avocados" adds avocados with a quantity of 2.
    private func addItem() {
        let text = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var name = text
        var quantity = "1"
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, let first = parts[0].first, first.isNumber,
           parts[0].allSatisfy({ $0.isNumber || $0 == "." || $0 == "/" }) {
            quantity = parts[0]
            name = parts[1]
        }
        withAnimation {
            store.addItem(name: name, quantity: quantity, to: newItemSection)
        }
        newItemText = ""
        addFieldFocused = true
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            EmptyCard(
                symbol: "cart",
                title: "No grocery list yet",
                message: emptyMessage
            )
            if canEdit {
                HStack(spacing: 10) {
                    if canGenerate {
                        Button {
                            openGenerate()
                        } label: {
                            Label("Generate List", systemImage: "sparkles")
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    Button {
                        addFieldFocused = true
                    } label: {
                        Label("Add Manually", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var emptyMessage: String {
        if !canEdit { return "Your organizer hasn't made a list yet. It'll show up here when they do." }
        if canGenerate { return "Make a list from this week's meal plan, or type items in to build it yourself." }
        return "Type items in above to build your list."
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if canGenerate {
                    Button("Generate List…", systemImage: "sparkles") { openGenerate() }
                }
                Button {
                    if isPro { showHistory = true } else { router.present(.paywall) }
                } label: {
                    Label(isPro ? "History…" : "History (Pro)…", systemImage: "clock.arrow.circlepath")
                }
                if !store.isEmpty {
                    ShareLink(item: store.shareText(includeCost: isPro), subject: Text("Grocery list")) {
                        Label("Share List", systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
                Toggle(isOn: $hideChecked) {
                    Label("Hide Checked Items", systemImage: "eye.slash")
                }
                .disabled(store.isEmpty)
                Button("Uncheck All", systemImage: "arrow.uturn.backward.circle") {
                    withAnimation { store.uncheckAll() }
                }
                .disabled(store.checkedCount == 0)
                if canEdit {
                    Divider()
                    Button("New Section…", systemImage: "folder.badge.plus") { showNewSection = true }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Grocery list options")
        }
    }

    private func openGenerate() {
        guard canGenerate else { return }
        addFieldFocused = false
        if isPro {
            showGenerate = true
        } else {
            // The Expo app sent organizers without Pro straight to the paywall.
            router.present(.paywall)
        }
    }
}

/// The top of the list: the days it covers and where it came from, what's left, and the cost
/// estimate (a Pro feature; without Pro it's a locked tile that opens the plans).
struct GroceryHeaderCard: View {
    var store: GroceryStore
    var isPro: Bool
    var onUpgrade: () -> Void

    @Environment(\.accent) private var accent

    init(store: GroceryStore, isPro: Bool, onUpgrade: @escaping () -> Void) {
        self.store = store
        self.isPro = isPro
        self.onUpgrade = onUpgrade
    }

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.bold())
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    statTile(
                        value: store.isEmpty ? "0" : "\(store.remainingCount)",
                        label: store.isEmpty ? "Items" : "Left of \(store.totalCount)",
                        symbol: "cart",
                        color: accent
                    )
                    if isPro {
                        statTile(
                            value: store.estimatedCost > 0 ? GroceryFormat.cost(store.estimatedCost) : "—",
                            label: "Estimated cost",
                            symbol: "dollarsign.circle",
                            color: .green
                        )
                    } else {
                        Button(action: onUpgrade) {
                            HStack(spacing: 10) {
                                IconTile(symbol: "lock.fill", color: .secondary, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    ProBadge()
                                    Text("Cost estimate")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                            .contentShape(.rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cost estimate, a Pro feature")
                        .accessibilityHint("Shows BigTable Pro plans")
                    }
                }

                if store.totalCount > 0 {
                    ProgressView(value: Double(store.checkedCount), total: Double(max(store.totalCount, 1)))
                        .tint(accent)
                        .accessibilityLabel("\(store.checkedCount) of \(store.totalCount) checked off")
                }
            }
        }
    }

    private var title: String {
        if let range = store.activeRange {
            return GroceryDates.label(start: range.start, end: range.end)
        }
        if store.isEmpty { return "This week's list" }
        if store.remainingCount == 0 { return "All checked off" }
        return "Your list"
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let source = store.source { parts.append(GroceryFormat.sourceLabel(source)) }
        if let generatedAt = store.generatedAt, !relativeTime(generatedAt).isEmpty { parts.append(relativeTime(generatedAt)) }
        if store.isSaving { parts.append("Saving…") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func statTile(value: String, label: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.bold().monospacedDigit())
                    .contentTransition(.numericText())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
