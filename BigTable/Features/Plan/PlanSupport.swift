import Foundation

/// One meal on the plan: a day of a week (by its Sunday) and breakfast, lunch or dinner.
nonisolated struct PlanSlotRef: Hashable, Sendable {
    var weekStart: String
    var day: DayOfWeek
    var slot: MealSlotType

    var id: String { "\(weekStart)|\(day.rawValue)|\(slot.rawValue)" }
    /// "Tuesday dinner".
    var title: String { "\(day.label) \(slot.label.lowercased())" }
    /// The calendar day, "YYYY-MM-DD".
    var isoDate: String { PlanDates.iso(weekStart: weekStart, day: day) }
}

/// The sheets the Plan tab opens for one meal.
nonisolated enum PlanSheet: Identifiable, Hashable, Sendable {
    /// Pick a recipe and add it as an entree, side, dessert or other.
    case recipePicker(PlanSlotRef, PlannerMealRole)
    /// Type a meal without a recipe ("Leftovers").
    case customMeal(PlanSlotRef)
    /// Choose a restaurant (or just name the night out).
    case dineOut(PlanSlotRef)
    /// The planned restaurant: map, address, phone, directions.
    case dineOutDetail(PlanSlotRef)
    /// Search packaged snacks to add.
    case snacks(PlanSlotRef)

    var ref: PlanSlotRef {
        switch self {
        case .recipePicker(let ref, _), .customMeal(let ref), .dineOut(let ref), .dineOutDetail(let ref), .snacks(let ref): ref
        }
    }

    var id: String {
        switch self {
        case .recipePicker(let ref, let role): "recipe-\(ref.id)-\(role.rawValue)"
        case .customMeal(let ref): "custom-\(ref.id)"
        case .dineOut(let ref): "dineout-\(ref.id)"
        case .dineOutDetail(let ref): "dineoutdetail-\(ref.id)"
        case .snacks(let ref): "snacks-\(ref.id)"
        }
    }
}

/// Calendar helpers for the plan's Sunday-start weeks.
nonisolated enum PlanDates {
    static func day(for date: Date, calendar: Calendar = .current) -> DayOfWeek {
        let weekday = calendar.component(.weekday, from: date)  // 1 = Sunday
        return DayOfWeek.allCases[max(0, min(6, weekday - 1))]
    }

    static func day(forISO iso: String) -> DayOfWeek {
        day(for: ISODay.date(from: iso) ?? .now)
    }

    static var todayISO: String { ISODay.string(from: .now) }

    static var currentWeekStart: String { ISODay.weekStart(containing: .now) }

    static func iso(weekStart: String, day: DayOfWeek) -> String {
        ISODay.adding(days: day.offset, to: weekStart)
    }

    static func date(weekStart: String, day: DayOfWeek) -> Date {
        ISODay.date(from: iso(weekStart: weekStart, day: day)) ?? .now
    }

    /// "14" for the day of the month.
    static func dayNumber(weekStart: String, day: DayOfWeek) -> String {
        String(Calendar.current.component(.day, from: date(weekStart: weekStart, day: day)))
    }

    /// "Oct 12 – 18", or "Sep 28 – Oct 4" across months.
    static func rangeLabel(weekStart: String) -> String {
        guard let start = ISODay.date(from: weekStart),
              let end = Calendar.current.date(byAdding: .day, value: 6, to: start) else { return weekStart }
        let sameMonth = Calendar.current.component(.month, from: start) == Calendar.current.component(.month, from: end)
        let first = start.formatted(.dateTime.month(.abbreviated).day())
        let last = sameMonth ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(first) – \(last)"
    }

    /// "Today", "Tomorrow", "Yesterday", or "Wednesday, Oct 15".
    static func dayTitle(iso: String) -> String {
        let today = todayISO
        if iso == today { return "Today" }
        if iso == ISODay.adding(days: 1, to: today) { return "Tomorrow" }
        if iso == ISODay.adding(days: -1, to: today) { return "Yesterday" }
        guard let date = ISODay.date(from: iso) else { return iso }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// "Wed, Oct 15".
    static func shortTitle(iso: String) -> String {
        guard let date = ISODay.date(from: iso) else { return iso }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Every day from `start` to `end`, inclusive (at most 60).
    static func dates(from start: String, to end: String) -> [String] {
        var result: [String] = []
        var cursor = start
        while cursor <= end, result.count < 60 {
            result.append(cursor)
            cursor = ISODay.adding(days: 1, to: cursor)
        }
        return result
    }
}

/// How a planned meal reads in a single line, and what fills a slot.
nonisolated enum PlanSlotText {
    /// The slot's headline: the restaurant, the first recipe, or the custom meal.
    static func primaryTitle(_ slot: PlannerSlot) -> String? {
        if let dineOut = slot.dineOut {
            let label = PlanDineOutFormat.displayLabel(dineOut)
            return label.isEmpty ? nil : label
        }
        if let first = slot.recipeItems.first?.title.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty {
            return first
        }
        let custom = (slot.customMeal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? nil : custom
    }

    static func primaryImage(_ slot: PlannerSlot) -> String? {
        slot.recipeItems.first?.imageUrl.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }
}

/// Restaurant addresses and links, as the Expo app tidied them.
nonisolated enum PlanDineOutFormat {
    private static let countries: Set<String> = [
        "united states", "united states of america", "usa", "us", "canada", "mexico", "united kingdom", "uk",
        "england", "scotland", "wales", "ireland", "australia", "new zealand",
    ]
    private static let broadWords = ["county", "parish", "district", "region", "province", "prefecture"]

    /// Drops trailing country, county and region parts: "12 Main St, Provo, UT 84601".
    static func conciseAddress(_ raw: String) -> String {
        var segments = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func isBroad(_ value: String) -> Bool {
            let normalized = value.lowercased()
            if countries.contains(normalized) { return true }
            return broadWords.contains { normalized.contains(" \($0)") }
        }
        while segments.count > 1, let last = segments.last, isBroad(last) {
            segments.removeLast()
        }
        return segments.joined(separator: ", ")
    }

    /// The label as saved ("Café Rio - 12 Main St, Provo"), with the address tidied.
    static func displayLabel(_ dineOut: PlannerDineOut) -> String {
        let trimmed = dineOut.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dineOut.name ?? "" }
        guard let range = trimmed.range(of: " - ") else { return conciseAddress(trimmed) }
        let venue = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let address = conciseAddress(String(trimmed[range.upperBound...]))
        return address.isEmpty ? venue : "\(venue) - \(address)"
    }

    /// The restaurant's name, or the label when it was just named ("Pizza night out").
    static func displayName(_ dineOut: PlannerDineOut) -> String {
        if let name = dineOut.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return displayLabel(dineOut)
    }

    /// Logos come from img.logo.dev/<domain>; the domain doubles as the website.
    static func website(_ dineOut: PlannerDineOut) -> URL? {
        if let site = dineOut.website?.trimmingCharacters(in: .whitespaces), !site.isEmpty {
            return URL(string: site.hasPrefix("http") ? site : "https://\(site)")
        }
        guard let logo = dineOut.logoUrl, let url = URL(string: logo), url.host() == "img.logo.dev" else { return nil }
        guard let domain = url.pathComponents.dropFirst().first?.removingPercentEncoding?.trimmingCharacters(in: .whitespaces),
              !domain.isEmpty else { return nil }
        return URL(string: "https://\(domain)")
    }

    static func phoneURL(_ phone: String?) -> URL? {
        guard let phone else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }

    /// Apple Maps with the place pinned.
    static func mapsURL(_ dineOut: PlannerDineOut) -> URL? {
        let name = displayName(dineOut)
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let latitude = dineOut.latitude, let longitude = dineOut.longitude {
            return URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(query)")
        }
        let address = (dineOut.address ?? name).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "https://maps.apple.com/?q=\(address)")
    }
}
