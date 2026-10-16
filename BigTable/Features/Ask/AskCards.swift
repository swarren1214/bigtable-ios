import SwiftUI

// The cards under Ask BigTable's replies, from the Ask design: the week's meals, a meal added
// to the plan, things added to the grocery list, and things checked off. Changes have Undo
// (then Redo), and a meal that would replace another asks first with Replace and Keep.

/// One card for one action.
struct AskActionCard: View {
    var action: AskAction
    var onToggle: () -> Void
    var onResolve: (_ replace: Bool) -> Void

    var body: some View {
        switch action.kind {
        case .week(let card):
            AskWeekCardView(card: card)
        case .plan(let change):
            AskPlanCard(change: change, isBusy: action.isBusy, onToggle: onToggle, onResolve: onResolve)
        case .groceryAdd(let change):
            AskGroceryAddCard(change: change, isBusy: action.isBusy, onToggle: onToggle)
        case .groceryCheck(let change):
            AskCheckOffCard(change: change, isBusy: action.isBusy, onToggle: onToggle)
        }
    }
}

/// The green of a checked item.
enum AskStyle {
    static let checkGreen = Color(hex: 0x1E9E6A)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
}

/// "ADDED TO THE PLAN", in small caps above a card.
struct AskCardLabel: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.3)
            .foregroundStyle(.secondary)
    }
}

/// Undo, or Redo once undone.
struct AskUndoButton: View {
    var undone: Bool
    var isBusy: Bool
    var action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            Text(undone ? "Redo" : "Undo")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .background(accent.opacity(0.12), in: .capsule)
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
    }
}

/// A round check: filled green with a checkmark, or an empty ring.
struct AskCheckCircle: View {
    var isOn: Bool
    var size: CGFloat = 22
    var ring: Color = Color(.systemGray3)

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(AskStyle.checkGreen)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(ring, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.3, bounce: 0.4), value: isOn)
        .accessibilityHidden(true)
    }
}

// MARK: - Week

/// The week's meals: day, photo and title; open days dashed and in italics.
struct AskWeekCardView: View {
    var card: AskWeekCard

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(card.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 14) }
                HStack(spacing: 10) {
                    Text(row.day)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    if row.title != nil {
                        RecipePhoto(url: row.imageUrl, cornerRadius: 8, symbolSize: 12)
                            .frame(width: 30, height: 30)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .frame(width: 30, height: 30)
                    }
                    if let title = row.title {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    } else {
                        Text("Nothing planned")
                            .font(.subheadline)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
        .background(AskStyle.cardBackground, in: .rect(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Plan

/// A meal Ask put on the plan (Undo, Redo), or one asking to replace what's there.
struct AskPlanCard: View {
    var change: AskPlanChange
    var isBusy: Bool
    var onToggle: () -> Void
    var onResolve: (_ replace: Bool) -> Void
    @Environment(\.accent) private var accent

    private var isUndone: Bool { change.status == .undone || change.status == .kept }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RecipePhoto(url: change.imageUrl, cornerRadius: 12, symbolSize: 18)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    AskCardLabel(text: label)
                    Text(change.status == .kept ? (change.existingTitle ?? change.title) : change.title)
                        .font(.headline)
                        .strikethrough(change.status == .undone)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if change.status == .done || change.status == .undone {
                    AskUndoButton(undone: change.status == .undone, isBusy: isBusy, action: onToggle)
                }
            }
            if change.status == .needsConfirmation {
                HStack(spacing: 8) {
                    Button { onResolve(true) } label: {
                        Text("Replace")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(accent, in: .capsule)

                    Button { onResolve(false) } label: {
                        Text("Keep")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .background(accent.opacity(0.12), in: .capsule)
                }
                .disabled(isBusy)
                .opacity(isBusy ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AskStyle.cardBackground, in: .rect(cornerRadius: 20, style: .continuous))
        .opacity(isUndone ? 0.55 : 1)
        .animation(.snappy, value: isUndone)
    }

    private var label: String {
        switch change.status {
        case .needsConfirmation: "Already planned"
        case .done: "Added to the plan"
        case .undone: "Removed from the plan"
        case .kept: "Kept as planned"
        }
    }

    private var subtitle: String {
        switch change.status {
        case .needsConfirmation:
            "\(change.ref.title) has \(change.existingTitle ?? "a meal"). Replace it?"
        case .done, .undone:
            change.detail
        case .kept:
            change.ref.title
        }
    }
}

// MARK: - Grocery list

/// Things Ask added to the grocery list, with their amounts and aisles.
struct AskGroceryAddCard: View {
    var change: AskGroceryChange
    var isBusy: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                AskCardLabel(text: change.undone ? "Taken off the grocery list" : "Added to the grocery list")
                Spacer()
                AskUndoButton(undone: change.undone, isBusy: isBusy, action: onToggle)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            ForEach(change.items) { line in
                Divider()
                HStack(spacing: 12) {
                    Text(line.name)
                        .font(.subheadline.weight(.medium))
                        .strikethrough(change.undone)
                    Spacer(minLength: 8)
                    Text(line.quantity.isEmpty ? line.section : "\(line.quantity) · \(line.section)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            Spacer().frame(height: 4)
        }
        .background(AskStyle.cardBackground, in: .rect(cornerRadius: 20, style: .continuous))
        .opacity(change.undone ? 0.55 : 1)
        .animation(.snappy, value: change.undone)
    }
}

/// Things Ask checked off, with green checks (empty again after Undo).
struct AskCheckOffCard: View {
    var change: AskGroceryChange
    var isBusy: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                AskCardLabel(text: change.undone ? "Back on the list" : "Checked off")
                Spacer()
                AskUndoButton(undone: change.undone, isBusy: isBusy, action: onToggle)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            ForEach(change.items) { line in
                Divider()
                HStack(spacing: 12) {
                    AskCheckCircle(isOn: !change.undone)
                    Text(line.quantity.isEmpty ? line.name : "\(line.name) · \(line.quantity)")
                        .font(.subheadline)
                        .strikethrough(!change.undone)
                        .foregroundStyle(change.undone ? Color.primary : Color.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
                .accessibilityValue(change.undone ? "Not checked" : "Checked")
            }
            Spacer().frame(height: 3)
        }
        .background(AskStyle.cardBackground, in: .rect(cornerRadius: 20, style: .continuous))
    }
}
