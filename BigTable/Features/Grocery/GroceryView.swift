import SwiftUI
import UIKit

/// The Grocery tab: the household's shopping list by aisle. Tap an item to check it off; the
/// header shows the days it covers, how much is left and (with BigTable Plus or Hearth+) the cost estimate. The
/// organizer can add, edit and swipe away items, make a list with AI, and restore an older
/// list from History. Everyone can share what's still needed.
struct GroceryView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accent) private var accent

    @State private var store = GroceryStore.shared
    @State private var hideChecked = false
    @State private var showGenerate = false
    @State private var showHistory = false
    @State private var showsPaywall = false
    @State private var paywallFeature: HearthPaywallFeature?
    @State private var showNewSection = false
    @State private var editing: GroceryItemEditTarget?
    @State private var newItemText = ""
    @State private var newItemSection = "Other"
    @FocusState private var addFieldFocused: Bool
    /// List or Pantry, remembered.
    @AppStorage("grocery.side") private var side = "list"

    private var isPro: Bool { model.hasPro }
    private var canEdit: Bool { model.isOrganizer }
    /// The snapshot API only lets the organizer save a whole list, so AI lists are theirs to
    /// make (as in the Expo app).
    private var canGenerate: Bool { model.isOrganizer && model.canUseAIGrocery }
    /// Reload when someone else signs in or the household changes (joining or leaving one).
    private var householdKey: String { "\(model.userID ?? "")|\(model.membership?.organizerProfileId ?? "")" }

    var body: some View {
        Group {
            if side == "pantry" {
                PantryView()
            } else {
                listSide
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { sidePicker }
        .navigationTitle(side == "pantry" ? "Pantry" : "Grocery")
        .navigationBarTitleDisplayMode(.large)
    }

    /// What you need (the list) or what you have (the pantry).
    private var sidePicker: some View {
        Picker("Show", selection: $side.animation(.snappy)) {
            Text("List").tag("list")
            Text("Pantry").tag("pantry")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    private var listSide: some View {
        content
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Grocery")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .bigTableToolbar(overHeader: false)
            .task(id: householdKey) { await store.load() }
            .refreshable {
                await store.flush()
                await KitchenStore.shared.syncNow()
                await store.load()
            }
            // The family changed the list on another phone.
            .onChange(of: KitchenStore.shared.revision) {
                Task {
                    await store.flush()
                    await store.load()
                }
            }
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
            .hearthPaywall(isPresented: $showsPaywall, feature: paywallFeature)
    }

    static let costFeature = HearthPaywallFeature("Grocery cost estimates", detail: "See about what the list will cost before you shop.", symbol: "dollarsign.circle")
    static let historyFeature = HearthPaywallFeature("Grocery history", detail: "Bring back an older list in a tap.", symbol: "clock.arrow.circlepath")
    static let generateFeature = HearthPaywallFeature("AI grocery lists", detail: "Built from the plan, sorted by aisle, with amounts and a cost estimate.", symbol: "wand.and.stars")

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
                    openPaywall(Self.costFeature)
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
                    Button(store.isChecked(item) ? "Mark as Needed" : "Check Off", menuIcon: store.isChecked(item) ? "circle" : "checkmark.circle") {
                        store.toggle(item)
                    }
                    if canEdit {
                        Button("Edit…", menuIcon: "pencil") {
                            editing = GroceryItemEditTarget(item: item, sectionName: section.name)
                        }
                        Button("Delete", menuIcon: "trash", role: .destructive) {
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
                        Label { Text(name) } icon: { Image.menuIcon(GroceryAisleStyle.symbol(name)) }.tag(name)
                    }
                }
                Divider()
                Button("New Section…", menuIcon: "folder.badge.plus") { showNewSection = true }
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
                    Button("Generate List…", menuIcon: "sparkles") { openGenerate() }
                }
                Button {
                    if isPro { showHistory = true } else { openPaywall(Self.historyFeature) }
                } label: {
                    Label { Text(isPro ? "History…" : "History (Plus)…") } icon: { Image.menuIcon("clock.arrow.circlepath") }
                }
                if !store.isEmpty {
                    ShareLink(item: store.shareText(includeCost: isPro), subject: Text("Grocery list")) {
                        Label { Text("Share List") } icon: { Image.menuIcon("square.and.arrow.up") }
                    }
                }
                Divider()
                Toggle(isOn: $hideChecked) {
                    Label { Text("Hide Checked Items") } icon: { Image.menuIcon("eye.slash") }
                }
                .disabled(store.isEmpty)
                Button("Uncheck All", menuIcon: "arrow.uturn.backward.circle") {
                    withAnimation { store.uncheckAll() }
                }
                .disabled(store.checkedCount == 0)
                if canEdit {
                    Divider()
                    Button("New Section…", menuIcon: "folder.badge.plus") { showNewSection = true }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Grocery list options")
        }
    }

    private func openPaywall(_ feature: HearthPaywallFeature) {
        paywallFeature = feature
        showsPaywall = true
    }

    private func openGenerate() {
        guard canGenerate else { return }
        addFieldFocused = false
        if isPro {
            showGenerate = true
        } else {
            // The Expo app sent organizers without Pro straight to the paywall.
            openPaywall(Self.generateFeature)
        }
    }
}

/// The top of the list: the days it covers and where it came from, what's left, and the cost
/// estimate (a Plus feature; without Pro it's a locked tile that opens the plans).
struct GroceryHeaderCard: View {
    var store: GroceryStore
    var isPro: Bool
    var onUpgrade: () -> Void

    @Environment(\.accent) private var accent
    @Environment(\.openURL) private var openURL
    /// This month's groceries budget from Suffice, when Suffice is on this device.
    @State private var sufficeBudget: HearthGroceryBudget?
    /// Showing another app's data here (Suffice's budget) is a Hearth+ feature.
    @State private var purchases = HearthPurchases.shared

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
                        .accessibilityLabel("Cost estimate, a Plus feature")
                        .accessibilityHint("Shows BigTable Plus plans")
                    }
                }

                if store.totalCount > 0 {
                    ProgressView(value: Double(store.checkedCount), total: Double(max(store.totalCount, 1)))
                        .tint(accent)
                        .accessibilityLabel("\(store.checkedCount) of \(store.totalCount) checked off")
                }

                if let budget = sufficeBudget, budget.limitCents > 0 {
                    Divider()
                    if purchases.hasHearthPlus {
                        sufficeRow(budget)
                    } else {
                        HearthPlusTeaser(from: .suffice, title: "Your Suffice grocery budget could show up here", detail: "See what's left in it next to the list, with Hearth+.")
                    }
                }
            }
        }
        .task { loadSufficeBudget() }
        .onReceive(NotificationCenter.default.publisher(for: Hearth.didChange)) { _ in loadSufficeBudget() }
    }

    /// Suffice's groceries budget, and whether what's left on the list fits in it. Tapping
    /// opens the budget in Suffice.
    private func sufficeRow(_ budget: HearthGroceryBudget) -> some View {
        let left = budget.leftCents
        let toBuy = isPro ? listCostCents : nil
        let after = toBuy.map { left - $0 }
        return Button {
            if let link = budget.link, let url = URL(string: link) { openURL(url) }
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: "chart.pie.fill", color: Self.sufficeGreen, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(left >= 0 ? "\(money(left, budget)) left in \(budget.name)" : "\(money(-left, budget)) over in \(budget.name)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(left >= 0 ? Color.primary : Color.red)
                    Group {
                        if let toBuy, let after {
                            Text("This list, about \(money(toBuy, budget)): " + (after >= 0 ? "leaves \(money(after, budget))" : "\(money(-after, budget)) over"))
                                .foregroundStyle(after >= 0 ? Color.secondary : Color.red)
                        } else {
                            Text("Of \(money(budget.limitCents, budget)) this month in Suffice")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the budget in Suffice")
    }

    /// What's still to buy should cost, in cents: the estimate scaled to the items left.
    private var listCostCents: Int? {
        guard store.estimatedCost > 0, store.totalCount > 0, store.remainingCount > 0 else { return nil }
        let share = Double(store.remainingCount) / Double(store.totalCount)
        return Int((store.estimatedCost * share * 100).rounded())
    }

    private func money(_ cents: Int, _ budget: HearthGroceryBudget) -> String {
        (Double(cents) / 100).formatted(.currency(code: budget.currencyCode).precision(.fractionLength(0)))
    }

    /// Suffice's green, for its budget.
    private static let sufficeGreen = Color(red: 0.23, green: 0.49, blue: 0.20)

    /// Suffice's groceries budget for this month; an older month's isn't shown.
    private func loadSufficeBudget() {
        guard !ScreenshotMode.isOn,
              let budget = Hearth.read(HearthGroceryBudget.self, from: .suffice)?.value,
              let month = Calendar.current.dateInterval(of: .month, for: .now)?.start,
              budget.month == HearthDay.string(from: month) else {
            if sufficeBudget != nil { sufficeBudget = nil }
            return
        }
        if budget != sufficeBudget { sufficeBudget = budget }
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
