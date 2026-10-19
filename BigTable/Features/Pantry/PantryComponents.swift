import SwiftUI
import UIKit

extension PantryPlace {
    var color: Color { Color(hex: kind.colorHex) }
}

/// Orange for running low, the house color for saved-for-a-meal, quiet otherwise.
enum PantryColors {
    static let warn = Color(hex: 0xC25E00)
    static let good = Color(hex: 0x1E9E6A)
}

/// A thin bar showing how full something is.
struct PantryLevelBar: View {
    var level: Double
    var color: Color
    var width: CGFloat = 44

    var body: some View {
        Capsule()
            .fill(Color(.systemFill))
            .frame(width: width, height: 6)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(color)
                    .frame(width: max(level > 0 ? 4 : 0, width * min(1, max(0, level))), height: 6)
            }
            .accessibilityHidden(true)
    }
}

/// A small jar that fills to the level: the Running out cards and the quick check.
struct PantryJar: View {
    var level: Double
    var color: Color
    var width: CGFloat = 26
    var height: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: width * 0.3, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .frame(width: width, height: height)
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: width * 0.22, style: .continuous)
                    .fill(color)
                    .frame(height: max(level > 0 ? 3 : 0, (height - 4) * min(1, max(0, level))))
                    .padding(2)
            }
            .accessibilityHidden(true)
    }
}

extension PantryLedger.Shortfall {
    /// "Short tonight", "Short Fri", "Out Sat".
    var badge: String {
        let today = ISODay.string(from: .now)
        let day: String
        if date == today {
            day = use?.slot == .dinner ? "tonight" : "today"
        } else if date == ISODay.string(from: .now.addingTimeInterval(86_400)) {
            day = "tomorrow"
        } else if let parsed = ISODay.date(from: date) {
            day = parsed.formatted(.dateTime.weekday(.abbreviated))
        } else {
            day = date
        }
        return (use == nil ? "Out " : "Short ") + day
    }

    var isUrgent: Bool {
        date <= ISODay.string(from: .now.addingTimeInterval(86_400))
    }
}

extension PantrySnapshot.Row {
    /// One line under the name: what's happening with it.
    var detail: String {
        if let shortfall {
            if let use = shortfall.use {
                return "\(use.mealTitle) needs \(PantryUnits.display(shortfall.missing, for: item)) more"
            }
            return "About when you usually run out"
        }
        if let days = daysLeft { return days == 0 ? "Use today" : "Use in \(days) day\(days == 1 ? "" : "s")" }
        if let next = savedFor.first { return "Saved for \(next.mealTitle)" }
        if amount.isOut { return "Out" }
        if amount.isUnsure { return "Not sure how much" }
        return "Plenty"
    }

    var amountText: String {
        amount.isOut ? "Out" : (amount.isUnsure ? "≈ " : "") + PantryUnits.display(amount.amount, for: item)
    }
}
