import Foundation
import SwiftUI
import UIKit

/// Keys for settings stored with @AppStorage. Keep every key here so views stay in sync.
nonisolated enum SettingsKey {
    /// Round grocery amounts up to warehouse sizes (the AI list's "Costco mode").
    static let warehouseSizes = "grocery.warehouseSizes"
    /// The App Store review prompt has been shown.
    static let reviewPrompted = "review.prompted"
    /// Meals marked cooked, counted toward asking for a review.
    static let cookedCount = "review.cookedCount"
    /// Push notifications were asked for.
    static let pushAsked = "push.asked"
    /// Push turned off in Profile › Notifications (so launches don't register again).
    static let pushDisabled = "push.disabled"
    /// The date range each grocery list covers, by snapshot id (the API doesn't store it).
    static let grocerySnapshotRanges = "grocery.snapshotRanges"
    static let appearance = "appearance.mode"
    /// Names from Caloma's family that "Add your family from Caloma?" was dismissed for, one
    /// per line, so it isn't offered for them again.
    static let calomaFamilyDismissed = "hearth.calomaFamilyDismissed"
}

/// BigTable's colors, from the BigTable designs on the Claude Design canvas.
nonisolated enum Brand {
    /// Tomato: warm like the old BigTable orange, but far enough from Sated's orange that the
    /// two apps don't look alike side by side. Deep enough for white text.
    static let defaultAccentHex: UInt32 = 0xD9472B
    static var defaultAccent: Color { Color(hex: defaultAccentHex) }

    /// The placeholder behind a recipe without a photo.
    static let recipeTile = Color(hex: 0xB4532A)
    /// Allergies and things someone must not eat.
    static let allergy = Color(hex: 0xD93B30)
    /// Dislikes and softer preferences.
    static let preference = Color(hex: 0xC46A00)
}

extension EnvironmentValues {
    /// BigTable's tint (the tomato of its icon). It used to be a setting, Accent Color.
    @Entry var accent: Color = Brand.defaultAccent
}

/// Settings › Appearance.
nonisolated enum AppearanceOption: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A person's color, for their avatar and their chip when choosing who's eating.
nonisolated enum PersonColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case teal, pink, indigo, purple, blue, orange, green, red, gray

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var hex: UInt32 {
        switch self {
        case .teal: 0x0E8A8A
        case .pink: 0xC2185B
        case .indigo: 0x5E5CE6
        case .purple: 0xAF52DE
        case .blue: 0x0A84FF
        case .orange: 0xFF9F0A
        case .green: 0x1E9E6A
        case .red: 0xD93B30
        case .gray: 0x8E8E93
        }
    }

    var color: Color { Color(hex: hex) }

    /// The API has no colors for people, so each gets one by their place in the household
    /// (stable as long as the order is).
    static func forIndex(_ index: Int) -> PersonColor {
        let order = allCases.filter { $0 != .gray }
        return order[((index % order.count) + order.count) % order.count]
    }

    /// For people outside the household (a profile in Community): by a stable hash of the id.
    static func forKey(_ key: String) -> PersonColor {
        forIndex(key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFFFFFF })
    }
}

extension MealSlotType {
    /// Each slot keeps one color everywhere: its icon tile, its check and its chip.
    var color: Color {
        switch self {
        case .breakfast: Color(hex: 0xC77700)
        case .lunch: Color(hex: 0x0E8A8A)
        case .dinner: Color(hex: 0x5E5CE6)
        }
    }
}

extension PlannerMealRole {
    var color: Color {
        switch self {
        case .entree: Color(hex: 0xD9472B)
        case .side: Color(hex: 0x1E9E6A)
        case .dessert: Color(hex: 0xC2185B)
        case .other: Color(hex: 0x8E8E93)
        }
    }
}

/// Snacks keep their own color, like a fourth slot.
nonisolated enum SnackStyle {
    static let color = Color(hex: 0xC2185B)
    static let symbol = "carrot"
}

/// Grocery sections from the API ("Produce", "Meat"…), with a color and symbol each.
nonisolated enum GroceryAisleStyle {
    static func color(_ section: String) -> Color {
        switch section.lowercased() {
        case "produce": Color(hex: 0x1E9E6A)
        case "meat", "meat & seafood", "seafood": Color(hex: 0xC2185B)
        case "dairy", "dairy & eggs": Color(hex: 0x0A7AFF)
        case "pantry": Color(hex: 0xC77700)
        case "bakery": Color(hex: 0xB07A2A)
        case "frozen": Color(hex: 0x0E8A8A)
        case "beverages": Color(hex: 0x5E5CE6)
        case "snacks": Color(hex: 0xAF52DE)
        case "household": Color(hex: 0x6C6C70)
        default: Color(hex: 0x8E8E93)
        }
    }

    static func symbol(_ section: String) -> String {
        switch section.lowercased() {
        case "produce": "leaf"
        case "meat", "meat & seafood", "seafood": "fish"
        case "dairy", "dairy & eggs": "drop"
        case "pantry": "cabinet"
        case "bakery": "birthday.cake"
        case "frozen": "snowflake"
        case "beverages": "cup.and.saucer"
        case "snacks": "popcorn"
        case "household": "house"
        default: "basket"
        }
    }
}

/// "iPhone" or "iPad", for text that names the device.
enum DeviceName {
    static var current: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

extension Color {
    nonisolated init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Reads "#RRGGBB".
    nonisolated init?(hexString: String) {
        guard hexString.hasPrefix("#"), hexString.count == 7, let value = UInt32(hexString.dropFirst(), radix: 16) else { return nil }
        self.init(hex: value)
    }
}

/// "35 min", "1 hr 30 min", "8 hr".
nonisolated func durationText(minutes: Int) -> String {
    guard minutes > 0 else { return "" }
    let hours = minutes / 60, rest = minutes % 60
    switch (hours, rest) {
    case (0, _): return "\(rest) min"
    case (_, 0): return "\(hours) hr"
    default: return "\(hours) hr \(rest) min"
    }
}
