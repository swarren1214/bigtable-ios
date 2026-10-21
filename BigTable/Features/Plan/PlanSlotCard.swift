import Foundation
import SwiftUI
import UIKit

/// One meal of the day (breakfast, lunch or dinner): its recipes with their roles, a custom
/// meal or a night out, snacks, whether it's been cooked, and who's eating. Organizers (and
/// members allowed to manage the plan) can add, change and remove things; everyone else sees
/// it read-only.
struct PlanSlotCard: View {
    var ref: PlanSlotRef
    var slotData: PlannerSlot
    var canManage: Bool
    /// Past days can't get new things (as in the Expo app), but can still be tidied.
    var isPast: Bool
    var faces: [Face]
    var onRequest: (PlanSheet) -> Void
    var onToggleCompleted: () -> Void

    @Environment(AppRouter.self) private var router
    @Environment(\.accent) private var accent
    @State private var showsMembers = false

    private var store: PlanStore { PlanStore.shared }
    private var canAdd: Bool { canManage && !isPast }
    private var hasMeal: Bool { !slotData.isEmpty }

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .padding(.vertical, 8)

                Divider()

                if hasMeal {
                    mealRows
                } else {
                    emptyPrompt
                }

                if !slotData.snackItems.isEmpty {
                    Divider().padding(.leading, 16)
                    snackRows
                }

                if !faces.isEmpty {
                    Divider().padding(.leading, 16)
                    whosEating
                }
            }
        }
        .opacity(store.isSaving(ref) ? 0.85 : 1)
        .animation(.snappy, value: slotData)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: ref.slot.symbol, color: ref.slot.color, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(ref.slot.label)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if slotData.completed {
                    Text("Cooked")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ref.slot.color)
                }
            }
            Spacer(minLength: 0)

            if store.isSaving(ref) {
                ProgressView()
                    .controlSize(.small)
            }

            if hasMeal {
                if canManage {
                    Button(action: onToggleCompleted) {
                        RoundCheck(isOn: slotData.completed, color: ref.slot.color, size: 26)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(slotData.completed ? "Cooked. Mark \(ref.slot.label.lowercased()) not cooked" : "Mark \(ref.slot.label.lowercased()) cooked")
                    .sensoryFeedback(.success, trigger: slotData.completed) { _, new in new }
                } else if slotData.completed {
                    RoundCheck(isOn: true, color: ref.slot.color, size: 26)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Cooked")
                }
            }

            if canAdd {
                addMenu
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Menu {
                ForEach(PlannerMealRole.allCases) { role in
                    Button(role.label) { onRequest(.recipePicker(ref, role)) }
                }
            } label: {
                Label { Text("Add Recipe") } icon: { Image.menuIcon("fork.knife") }
            }
            Button {
                onRequest(.customMeal(ref))
            } label: {
                Label { Text("Custom Meal") } icon: { Image.menuIcon("pencil") }
            }
            Button {
                onRequest(.dineOut(ref))
            } label: {
                Label { Text("Dine Out") } icon: { Image.menuIcon("storefront") }
            }
            .disabled(slotData.dineOut != nil)
            Button {
                onRequest(.snacks(ref))
            } label: {
                Label { Text("Snacks") } icon: { Image.menuIcon(SnackStyle.symbol) }
            }
            if hasMeal || !slotData.snackItems.isEmpty {
                Divider()
                Button(role: .destructive) {
                    Task { await store.clearSlot(ref) }
                } label: {
                    Label { Text("Clear \(ref.slot.label)") } icon: { Image.menuIcon("trash", role: .destructive) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityLabel("Add to \(ref.slot.label.lowercased())")
    }

    // MARK: Meal

    @ViewBuilder
    private var mealRows: some View {
        if let dineOut = slotData.dineOut {
            dineOutRow(dineOut)
        } else if !slotData.recipeItems.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(slotData.recipeItems.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().padding(.leading, 80) }
                    recipeRow(item, index: index)
                }
            }
        } else if let custom = slotData.customMeal?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            customMealRow(custom)
        }
    }

    private func recipeRow(_ item: PlannerMealItem, index: Int) -> some View {
        HStack(spacing: 12) {
            RecipePhoto(url: item.imageUrl, cornerRadius: 12, symbolSize: 18)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    TagLabel(text: item.role.label, color: item.role.color)
                    if item.hasUpdateAvailable == true {
                        TagLabel(text: "Update available", color: .blue)
                    }
                }
            }
            Spacer(minLength: 0)
            if item.hasUpdateAvailable == true, canManage {
                Button("Use Latest") {
                    Task { await store.useLatestVersion(at: index, in: ref) }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.primary)
                .accessibilityLabel("Use the latest version of \(item.title)")
            } else if item.recipeId != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { open(item) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open recipe") { open(item) }
        .contextMenu {
            if item.recipeId != nil {
                Button {
                    open(item)
                } label: {
                    Label { Text("View Recipe") } icon: { Image.menuIcon("book") }
                }
            }
            if canManage {
                Picker(selection: Binding(
                    get: { item.role },
                    set: { role in Task { await store.setRole(role, at: index, in: ref) } }
                )) {
                    ForEach(PlannerMealRole.allCases) { role in
                        Text(role.label).tag(role)
                    }
                } label: {
                    Label { Text("Role") } icon: { Image.menuIcon("tag") }
                }
                .pickerStyle(.menu)

                if slotData.recipeItems.count > 1 {
                    if index > 0 {
                        Button {
                            Task { await store.moveRecipe(at: index, by: -1, in: ref) }
                        } label: {
                            Label { Text("Move Up") } icon: { Image.menuIcon("arrow.up") }
                        }
                    }
                    if index < slotData.recipeItems.count - 1 {
                        Button {
                            Task { await store.moveRecipe(at: index, by: 1, in: ref) }
                        } label: {
                            Label { Text("Move Down") } icon: { Image.menuIcon("arrow.down") }
                        }
                    }
                }
                if item.hasUpdateAvailable == true {
                    Button {
                        Task { await store.useLatestVersion(at: index, in: ref) }
                    } label: {
                        Label { Text("Use Latest Version") } icon: { Image.menuIcon("arrow.triangle.2.circlepath") }
                    }
                }
                Divider()
                Button(role: .destructive) {
                    Task { await store.removeRecipe(at: index, in: ref) }
                } label: {
                    Label { Text("Remove from \(ref.slot.label)") } icon: { Image.menuIcon("trash", role: .destructive) }
                }
            }
        }
    }

    private func open(_ item: PlannerMealItem) {
        guard let id = item.recipeId else { return }
        router.present(.recipe(id: id, versionID: item.recipeVersionId))
    }

    private func dineOutRow(_ dineOut: PlannerDineOut) -> some View {
        HStack(spacing: 12) {
            PlanDineOutLogo(url: dineOut.logoUrl, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("DINE OUT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(PlanDineOutFormat.displayName(dineOut))
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if let address = dineOut.address, !address.isEmpty {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { onRequest(.dineOutDetail(ref)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the map, phone and directions")
        .contextMenu {
            Button {
                onRequest(.dineOutDetail(ref))
            } label: {
                Label { Text("Details") } icon: { Image.menuIcon("info.circle") }
            }
            if canManage {
                Button {
                    onRequest(.dineOut(ref))
                } label: {
                    Label { Text("Change Restaurant") } icon: { Image.menuIcon("storefront") }
                }
                Divider()
                Button(role: .destructive) {
                    Task { await store.removeDineOut(in: ref) }
                } label: {
                    Label { Text("Remove Dine Out") } icon: { Image.menuIcon("trash", role: .destructive) }
                }
            }
        }
    }

    private func customMealRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: "pencil", color: ref.slot.color, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("CUSTOM MEAL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.body.weight(.semibold))
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture {
            if canManage { onRequest(.customMeal(ref)) }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if canManage {
                Button {
                    onRequest(.customMeal(ref))
                } label: {
                    Label { Text("Edit") } icon: { Image.menuIcon("pencil") }
                }
                Button(role: .destructive) {
                    Task { await store.clearMeal(in: ref) }
                } label: {
                    Label { Text("Remove") } icon: { Image.menuIcon("trash", role: .destructive) }
                }
            }
        }
    }

    // MARK: Empty

    private var emptyPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(canAdd ? "Nothing planned yet." : "Nothing planned.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if canAdd {
                FlowLayout(spacing: 8) {
                    quickAction("Recipe", "fork.knife") { onRequest(.recipePicker(ref, .entree)) }
                    quickAction("Custom", "pencil") { onRequest(.customMeal(ref)) }
                    quickAction("Dine Out", "storefront") { onRequest(.dineOut(ref)) }
                    if slotData.snackItems.isEmpty {
                        quickAction("Snacks", SnackStyle.symbol) { onRequest(.snacks(ref)) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func quickAction(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).lineLimit(1)
            }
                .font(.subheadline.weight(.semibold))
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .foregroundStyle(.primary)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(title.lowercased()) to \(ref.slot.label.lowercased())")
    }

    // MARK: Snacks

    private var snackRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(slotData.snackItems.enumerated()), id: \.offset) { index, snack in
                if index > 0 { Divider().padding(.leading, 72) }
                HStack(spacing: 12) {
                    PlanSnackImage(url: snack.imageUrl, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snack.description)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        let details = [snack.brandOwner, snack.calories.map { "\(Int($0.rounded())) kcal" }].compactMap { $0 }
                        if !details.isEmpty {
                            Text(details.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    TagLabel(text: "Snack", color: SnackStyle.color)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .contextMenu {
                    if canManage {
                        Button(role: .destructive) {
                            Task { await store.removeSnack(at: index, in: ref) }
                        } label: {
                            Label { Text("Remove Snack") } icon: { Image.menuIcon("trash", role: .destructive) }
                        }
                    }
                }
                .accessibilityAction(named: "Remove snack") {
                    guard canManage else { return }
                    Task { await store.removeSnack(at: index, in: ref) }
                }
            }
        }
    }

    // MARK: Who's eating

    private var excluded: Set<String> { Set(slotData.excludedMembers) }

    private var whosEating: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { showsMembers.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                    Text("Who's eating")
                        .font(.subheadline.weight(.semibold))
                    Text("\(faces.filter { !excluded.contains($0.name) }.count)/\(faces.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    FacePile(faces: Array(faces.prefix(6)), skipped: excluded, size: 24)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showsMembers ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Who's eating, \(faces.filter { !excluded.contains($0.name) }.count) of \(faces.count)")
            .accessibilityHint(showsMembers ? "Hides the people" : "Shows the people")

            if showsMembers {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(faces) { face in
                            memberButton(face)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity)
            }
        }
    }

    private func memberButton(_ face: Face) -> some View {
        let isOut = excluded.contains(face.name)
        return Button {
            Task { await store.toggleExcluded(face.name, in: ref) }
        } label: {
            VStack(spacing: 4) {
                MemberAvatar(name: face.name, color: face.color, url: face.url, size: 44, hearthName: face.name)
                    .opacity(isOut ? 0.35 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if !isOut {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, accent)
                                .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                        }
                    }
                Text(face.name.split(separator: " ").first.map(String.init) ?? face.name)
                    .font(.caption)
                    .foregroundStyle(isOut ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(width: 56)
        }
        .buttonStyle(.plain)
        .disabled(!canManage)
        .accessibilityLabel(face.name)
        .accessibilityValue(isOut ? "Not eating" : "Eating")
        .accessibilityHint(canManage ? (isOut ? "Includes them" : "Leaves them out") : "")
    }
}

/// A restaurant's logo, or a storefront tile when there isn't one (or it won't load).
struct PlanDineOutLogo: View {
    var url: String?
    var size: CGFloat = 44
    @Environment(\.accent) private var accent

    var body: some View {
        Group {
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Image(systemName: "storefront.fill")
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(accent.opacity(0.14))
    }
}

/// A packaged snack's photo, fit on white like a product shot, or a snack tile.
struct PlanSnackImage: View {
    var url: String?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(3)
                    } else {
                        fallback
                    }
                }
                .background(Color.white)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Image(systemName: SnackStyle.symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(SnackStyle.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SnackStyle.color.opacity(0.14))
    }
}
