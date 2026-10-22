import Combine
import SwiftUI
import UIKit

/// The Pantry side of the Grocery tab: a Suffice receipt waiting to be put away, what runs out
/// before the next shop (by the plan), what to use up, and the shelves by place. It keeps
/// itself current from receipts, check-offs and cooked meals; people correct it by talking,
/// a quick check, or editing an item.
struct PantryView: View {
    /// List or Pantry: the switch scrolls with the page, under the title.
    @Binding var side: String

    @Environment(\.accent) private var accent
    @State private var kitchen = KitchenStore.shared
    @State private var placeID = PantryPlace.fridgeID
    @State private var showVoice = false
    @State private var showCheck = false
    @State private var showAdd = false
    @State private var receipt: HearthReceipt?
    @State private var listAdded: Set<String> = []
    @State private var hearthTick = 0

    var body: some View {
        let snapshot = kitchen.pantrySnapshot()
        let receipts = { _ = hearthTick; return kitchen.pendingReceipts() }()
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroceryTabHeader(side: $side)
                if let first = receipts.first {
                    receiptCard(first)
                }
                if snapshot.rows.isEmpty {
                    emptyState
                } else {
                    if !snapshot.runningOut.isEmpty { runningOut(snapshot) }
                    if !snapshot.useItUp.isEmpty { useItUp(snapshot) }
                    shelves(snapshot)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
            .frame(maxWidth: BigTableScreen<EmptyView>.readableWidth)
            .frame(maxWidth: .infinity)
        }
        // The app's color header and large white title, like the other tabs.
        .colorHeader("Pantry")
        .refreshable { await kitchen.syncNow() }
        .toolbar {
            // One menu on the left, like the List side's, so the profile photo stays at the far right.
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Tell the Pantry…", menuIcon: "mic") { showVoice = true }
                    Button("Quick Check…", menuIcon: "checklist") { showCheck = true }
                    Button("Add Item…", menuIcon: "plus") { showAdd = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Pantry options")
                // White over the color header, like the other toolbar buttons.
                .tint(.white)
            }
        }
        // Ask, notifications and the profile photo (always last), as on every tab.
        .bigTableToolbar()
        .fullScreenCover(isPresented: $showVoice) { PantryVoiceView() }
        .sheet(isPresented: $showCheck) { PantryCheckView() }
        .sheet(isPresented: $showAdd) { PantryAddView(placeID: placeID) }
        .sheet(item: $receipt) { receipt in ReceiptPutAwayView(receipt: receipt) }
        .onReceive(NotificationCenter.default.publisher(for: Hearth.didChange)) { _ in hearthTick += 1 }
        .task {
            kitchen.compactPantryIfDue()
            if !GroceryStore.shared.hasLoaded { await GroceryStore.shared.load() }
        }
    }

    // MARK: Receipt

    private func receiptCard(_ receipt: HearthReceipt) -> some View {
        let food = receipt.lines.filter(\.isFood).count
        let other = receipt.lines.count - food
        return Button {
            self.receipt = receipt
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    IconTile(symbol: "receipt", color: PantryColors.good, size: 44, filled: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FROM SUFFICE · \(receipt.purchasedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PantryColors.good)
                        Text("Your \(receipt.store) run is ready to put away")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                }
                HStack(alignment: .bottom) {
                    Text("\(food) groceries\(other > 0 ? " · \(other) not food, left in Suffice" : "")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text("Put Away")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(accent, in: Capsule())
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Not Now", menuIcon: "xmark") { kitchen.dismissReceipt(receipt) }
        }
    }

    // MARK: Running out

    private func runningOut(_ snapshot: PantrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Running out", trailing: "Before your next shop")
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(snapshot.runningOut) { row in
                        runwayCard(row)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -16)
        }
    }

    private func runwayCard(_ row: PantrySnapshot.Row) -> some View {
        let shortfall = row.shortfall
        let color = shortfall?.isUrgent == true ? accent : PantryColors.warn
        let listed = row.onList || listAdded.contains(row.id)
        return VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                PantryItemView(itemID: row.id)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .bottom) {
                        PantryJar(level: row.amount.level, color: color)
                        Spacer()
                        Text(shortfall?.badge ?? "")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(color)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.item.name)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(minHeight: 52, alignment: .top)
                }
            }
            .buttonStyle(.plain)
            Button {
                listAdded.insert(row.id)
                Task { await kitchen.addToGroceryList(row.item) }
            } label: {
                Text(listed ? "On your list" : "Add \(row.item.usualBuy.map { String($0.prefix(14)) } ?? "to list")")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .foregroundStyle(listed ? PantryColors.good : Color.primary)
                    .background(listed ? PantryColors.good.opacity(0.13) : Color(.tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(listed)
        }
        .padding(14)
        .frame(width: 162)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }

    // MARK: Use it up

    private func useItUp(_ snapshot: PantrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Use it up", trailing: nil)
            VStack(spacing: 0) {
                ForEach(Array(snapshot.useItUp.enumerated()), id: \.element.id) { index, row in
                    NavigationLink {
                        PantryItemView(itemID: row.id)
                    } label: {
                        HStack(spacing: 12) {
                            let days = row.daysLeft ?? 0
                            Text(days == 0 ? "Today" : "\(days) day\(days == 1 ? "" : "s")")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(PantryColors.warn)
                                .frame(width: 62, height: 30)
                                .background(PantryColors.warn.opacity(0.14), in: Capsule())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.item.name).foregroundStyle(.primary)
                                Text(row.savedFor.first.map { "For \($0.mealTitle)" } ?? "\(row.amountText) · not in the plan")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if index < snapshot.useItUp.count - 1 { Divider().padding(.leading, 90) }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
        }
    }

    // MARK: Shelves

    private func shelves(_ snapshot: PantrySnapshot) -> some View {
        let rows = snapshot.rows(in: placeID)
        return VStack(alignment: .leading, spacing: 10) {
            header("On the shelves", trailing: nil)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(snapshot.places) { place in
                        let on = place.id == placeID
                        Button {
                            withAnimation(.snappy) { placeID = place.id }
                        } label: {
                            HStack(spacing: 6) {
                                Text(place.name)
                                Text("\(snapshot.count(in: place.id))")
                                    .monospacedDigit()
                                    .opacity(0.6)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(on ? Color(.systemBackground) : .primary)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(on ? Color.primary : Color(.secondarySystemGroupedBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    NavigationLink {
                        PantryContainersView()
                    } label: {
                        Label("Containers", systemImage: "takeoutbag.and.cup.and.straw")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -16)

            if rows.isEmpty, let place = snapshot.places.first(where: { $0.id == placeID }) {
                PantryPlaceEmptyState(place: place) {
                    showVoice = true
                } onAdd: {
                    showAdd = true
                }
                .id(place.id)
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        NavigationLink {
                            PantryItemView(itemID: row.id)
                        } label: {
                            shelfRow(row)
                        }
                        .buttonStyle(.plain)
                        if index < rows.count - 1 { Divider().padding(.leading, 16) }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
            }
            Text("Kept current from your receipts in Suffice, what you check off at the store, and the meals you mark cooked.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func shelfRow(_ row: PantrySnapshot.Row) -> some View {
        let warn = row.shortfall != nil || row.daysLeft != nil
        let saved = !warn && !row.savedFor.isEmpty
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(row.detail)
                    .font(.footnote.weight(warn ? .semibold : .regular))
                    .foregroundStyle(warn ? PantryColors.warn : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(row.amountText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                PantryLevelBar(level: row.amount.level, color: warn ? PantryColors.warn : Color(.systemGray2))
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
        .contentShape(.rect)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(symbol: "cabinet", color: accent, size: 48)
            Text("Your pantry fills itself in")
                .font(.title3.weight(.semibold))
            Text("Check things off at the store, mark meals cooked, or put away a receipt from Suffice, and BigTable keeps count. To start, tell it what you have.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // Side by side when they fit on one line each; stacked on narrow screens.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { emptyButtons }
                VStack(alignment: .leading, spacing: 10) { emptyButtons }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var emptyButtons: some View {
        Button {
            showVoice = true
        } label: {
            Label("Tell the Pantry", systemImage: "mic.fill")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 40)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        Button {
            showAdd = true
        } label: {
            Text("Add Something")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 40)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(.primary)
    }

    private func header(_ title: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.weight(.bold))
            Spacer()
            if let trailing {
                Text(trailing).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// An empty place (the fridge, the freezer, the garage): a shelf drawn in the place's color,
/// what usually goes there, and the two quickest ways to fill it.
struct PantryPlaceEmptyState: View {
    let place: PantryPlace
    var onSay: () -> Void
    var onAdd: () -> Void

    private var title: String {
        switch place.kind {
        case .fridge: "The fridge is empty, for now"
        case .freezer: "Nothing in the freezer yet"
        case .pantry: "The pantry shelves are bare"
        case .other: "Nothing in the \(place.name.lowercased()) yet"
        }
    }

    private var detail: String {
        switch place.kind {
        case .fridge: "Milk, eggs, cheese, tonight's chicken. Say what's in there once, and shopping and cooking keep it current."
        case .freezer: "Meat for later, frozen veggies, the waffles. Tell BigTable once and it counts down as you cook."
        case .pantry: "Rice, pasta, cans and snacks. Say a few at a time, like “8 pounds of rice and 6 cans of beans.”"
        case .other: "Bulk bags and backups live here. Name a container, like “the rice bucket is half full,” to track how full it is."
        }
    }

    private var examples: [String] {
        switch place.kind {
        case .fridge: ["2 gallons of milk", "3 dozen eggs", "a pound of butter"]
        case .freezer: ["4 lb ground beef", "2 bags of peas", "16 burritos"]
        case .pantry: ["8 lb rice", "6 cans of beans", "4 boxes of pasta"]
        case .other: ["25 lb oats", "the rice bucket is half full"]
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            shelf
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowingChips(examples: examples, color: place.color)
            HStack(spacing: 10) {
                Button(action: onSay) {
                    Label("Say What's in It", systemImage: "mic.fill")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .frame(height: 40)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                Button(action: onAdd) {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .frame(height: 40)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.primary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26, style: .continuous))
    }

    /// Three empty shelves in an open cabinet, the place's symbol on the middle one.
    private var shelf: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(place.color.opacity(0.10))
                .frame(width: 112, height: 112)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(place.color.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                .frame(width: 84, height: 88)
            VStack(spacing: 20) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(place.color.opacity(0.28))
                        .frame(width: 64, height: 3)
                }
            }
            .offset(y: 4)
            Image(systemName: place.kind.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(place.color)
                .frame(width: 48, height: 48)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                .overlay(Circle().strokeBorder(place.color.opacity(0.35), lineWidth: 1.5))
        }
        .accessibilityHidden(true)
    }
}

/// Things you might say, as quiet chips that wrap.
private struct FlowingChips: View {
    let examples: [String]
    let color: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(spacing: 6) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(examples, id: \.self) { example in
            Text("“\(example)”")
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(color.opacity(0.12), in: Capsule())
        }
    }
}
