import SwiftUI

/// Make a grocery list with AI from the meals on the plan (the Expo app's "Magic Grocery
/// List"): pick up to seven days, choose warehouse sizes, add anything the AI should know,
/// then review the list before it replaces (or joins) the current one. A Pro feature.
struct GroceryGenerateView: View {
    var store: GroceryStore

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(Subscriptions.self) private var subscriptions
    @AppStorage(SettingsKey.warehouseSizes) private var costcoMode = true

    @State private var start: Date
    @State private var end: Date
    @State private var overwrite = true
    @State private var prompt = ""
    @State private var isGenerating = false
    @State private var preview: GroceryPreview?
    @State private var showPaywall = false
    @State private var message: String?

    /// Defaults to the Plan tab's week (Sunday to Saturday), starting no earlier than today.
    init(store: GroceryStore, weekStart: String) {
        self.store = store
        let today = Calendar.current.startOfDay(for: .now)
        let sunday = GroceryDates.date(weekStart)
        let saturday = Calendar.current.date(byAdding: .day, value: 6, to: sunday) ?? sunday
        let first = max(sunday, today)
        _start = State(initialValue: first)
        _end = State(initialValue: max(saturday, first))
    }

    private var isPro: Bool { model.usage?.isPro == true || subscriptions.isPro }
    private var today: Date { Calendar.current.startOfDay(for: .now) }
    private var latestEnd: Date { Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start }
    private var dayCount: Int { (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) + 1 }

    var body: some View {
        NavigationStack {
            Form {
                if !isPro {
                    Section {
                        GroceryUpgradeRow { showPaywall = true }
                    }
                }

                Section {
                    DatePicker("From", selection: $start, in: today..., displayedComponents: .date)
                    DatePicker("To", selection: $end, in: start...latestEnd, displayedComponents: .date)
                } header: {
                    Text("Days")
                } footer: {
                    Text("Up to 7 days. The list covers the meals planned for \(dayCount == 1 ? "this day" : "these \(dayCount) days").")
                }

                Section {
                    Toggle(isOn: $costcoMode) {
                        Label("Warehouse sizes", systemImage: "shippingbox")
                    }
                    if !store.isEmpty {
                        Toggle(isOn: $overwrite) {
                            Label("Replace current list", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                } header: {
                    Text("Options")
                } footer: {
                    if store.isEmpty {
                        Text("Warehouse sizes rounds up to Costco-style packs, with a note on what's left over.")
                    } else {
                        Text("Warehouse sizes rounds up to Costco-style packs. Turn off Replace to keep what's on your list and add the new items to it.")
                    }
                }

                Section("Anything else?") {
                    TextField("We're having guests Saturday, skip gluten on Sunday…", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: prompt) { _, value in
                            if value.count > 500 { prompt = String(value.prefix(500)) }
                        }
                }

                Section {
                    Button {
                        Task { await generate() }
                    } label: {
                        HStack(spacing: 10) {
                            if isGenerating {
                                ProgressView()
                                Text("Making your list…")
                            } else {
                                Image(systemName: "sparkles")
                                Text("Generate List")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(isGenerating || !isPro)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(isPro ? "BigTable Pro: unlimited AI grocery lists." : "AI grocery lists are part of BigTable Pro.")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
            }
            .disabled(isGenerating)
            .navigationTitle("Generate List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .disabled(isGenerating)
                }
            }
            .onChange(of: start) { _, value in
                if end < value { end = value }
                let last = Calendar.current.date(byAdding: .day, value: 6, to: value) ?? value
                if end > last { end = last }
            }
            .navigationDestination(item: $preview) { preview in
                GroceryPreviewView(store: store, preview: preview) {
                    dismiss()
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .alert("Couldn't make a list", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
        .interactiveDismissDisabled(isGenerating)
    }

    private func generate() async {
        guard isPro else {
            showPaywall = true
            return
        }
        isGenerating = true
        defer { isGenerating = false }
        do {
            preview = try await store.generate(
                start: ISODay.string(from: start),
                end: ISODay.string(from: end),
                weekStart: router.weekStart,
                costcoMode: costcoMode,
                overwrite: overwrite,
                prompt: prompt
            )
        } catch is CancellationError {
            return
        } catch let error as APIError {
            if error.isLimitReached || error.code == "LIMIT_REACHED" || (error.isForbidden && model.isOrganizer) {
                showPaywall = true
            } else if error.code == "PLAN_EMPTY" {
                message = "No meals are planned for those days. Plan some meals, then make your grocery list."
            } else {
                message = error.localizedDescription
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

/// The locked state: what Pro adds here, and a way to the plans.
struct GroceryUpgradeRow: View {
    var action: () -> Void
    @Environment(\.accent) private var accent

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconTile(symbol: "sparkles", color: accent, size: 40, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Upgrade to Pro").font(.headline)
                        ProBadge()
                    }
                    Text("Unlock AI grocery lists, cost estimates and list history.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The list the AI made, before it's saved: every item by section, marked New or already on
/// the list. Saving makes it the household's active list.
struct GroceryPreviewView: View {
    var store: GroceryStore
    var preview: GroceryPreview
    var onSaved: () -> Void

    init(store: GroceryStore, preview: GroceryPreview, onSaved: @escaping () -> Void) {
        self.store = store
        self.preview = preview
        self.onSaved = onSaved
    }

    @Environment(AppModel.self) private var model
    @Environment(Subscriptions.self) private var subscriptions
    @State private var isSaving = false
    @State private var error: String?

    private var isPro: Bool { model.usage?.isPro == true || subscriptions.isPro }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(GroceryDates.label(start: preview.start, end: preview.end))
                        .font(.title3.bold())
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            ForEach(preview.sections) { section in
                Section {
                    ForEach(section.items) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                if let meals = GroceryFormat.meals(item.meals) {
                                    Text(meals)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(item.quantity)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                            if !preview.overwrite {
                                if store.isOnCurrentList(item, section: section.name) {
                                    TagLabel(text: "Existing", color: .secondary)
                                } else {
                                    TagLabel(text: "New", color: GroceryAisleStyle.color(section.name))
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Label(section.name, systemImage: GroceryAisleStyle.symbol(section.name))
                        .foregroundStyle(GroceryAisleStyle.color(section.name))
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 10) {
                        if isSaving { ProgressView() }
                        Text(isSaving ? "Saving…" : "Save List")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glassProminent)
                .disabled(isSaving)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Review List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save List", systemImage: "checkmark") {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
        .navigationBarBackButtonHidden(isSaving)
        .errorAlert($error, title: "Couldn't save the list")
    }

    private var summary: String {
        var parts = ["\(preview.itemCount) \(preview.itemCount == 1 ? "item" : "items")"]
        if isPro, preview.estimatedCost > 0 {
            parts.append("about \(GroceryFormat.cost(preview.estimatedCost))")
        }
        parts.append(preview.overwrite ? "replaces your current list" : "added to your current list")
        return parts.joined(separator: " · ")
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.publish(preview)
            onSaved()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
