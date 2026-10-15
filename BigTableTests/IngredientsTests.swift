import Foundation
import Testing
@testable import BigTable

/// The ingredient parsing ported from the Expo app's `lib/recipe-ingredients.ts`, checked
/// against what that code produced, so recipes read the same in both apps.
struct IngredientsTests {
    @Test(arguments: [
        ("1", 1.0), ("2.5", 2.5), ("1/2", 0.5), ("1 1/2", 1.5), ("1½", 1.5), ("½", 0.5), ("1-1/2", 1.5), ("11/2", 1.5),
    ])
    func amountsParse(text: String, value: Double) {
        #expect(Ingredients.parseAmount(text) == value)
    }

    @Test func notAnAmount() {
        #expect(Ingredients.parseAmount("a few") == nil)
        #expect(Ingredients.parseAmount("") == nil)
    }

    @Test func amountsFormatLikeTheExpoApp() {
        #expect(Ingredients.formatAmount(2) == "2")
        #expect(Ingredients.formatAmount(1.5) == "1.5")
        #expect(Ingredients.formatAmount(1.0 / 3) == "0.33")
        #expect(Ingredients.formatAmount(nil) == "")
    }

    @Test func parsesAFullLine() {
        let line = Ingredients.parseLine("2 1/2 lb chicken thighs")
        #expect(line.amount == 2.5)
        #expect(line.measurementType == "lb")
        #expect(line.name == "chicken thighs")
    }

    @Test func parsesCompactMeasurements() {
        let line = Ingredients.parseLine("1/2cup sugar")
        #expect(line.amount == 0.5)
        #expect(line.measurementType == "cup")
        #expect(line.name == "sugar")
    }

    @Test func aliasesMapToStoredValues() {
        #expect(Ingredients.parseLine("3 tablespoons butter").measurementType == "tbsp")
        #expect(Ingredients.parseLine("2 cups flour").measurementType == "cups")
        #expect(Ingredients.parseLine("4 cloves garlic").measurementType == "clove")
    }

    @Test func countsHaveNoMeasurement() {
        let eggs = Ingredients.parseLine("4 eggs")
        #expect(eggs.amount == 4)
        #expect(eggs.measurementType == nil)
        #expect(eggs.name == "eggs")
    }

    @Test func linesWithoutAnAmountKeepTheirName() {
        let line = Ingredients.parseLine("Salt and pepper to taste")
        #expect(line.amount == nil)
        #expect(line.name == "Salt and pepper to taste")
    }

    @Test func displayUsesKitchenFractions() {
        #expect(Ingredients.line(RecipeIngredientInput(amount: 1.5, measurementType: "cup", name: "flour")) == "1 ½ c flour")
        #expect(Ingredients.plainLine(RecipeIngredientInput(amount: 1.5, measurementType: "cup", name: "flour")) == "1.5 cup flour")
    }
}

struct ISODayTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }

    @Test func weekStartsOnSunday() {
        let wednesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        #expect(ISODay.weekStart(containing: wednesday, calendar: calendar) == "2026-10-11")
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11))!
        #expect(ISODay.weekStart(containing: sunday, calendar: calendar) == "2026-10-11")
    }

    @Test func roundTrips() {
        let date = ISODay.date(from: "2026-02-28", calendar: calendar)!
        #expect(ISODay.string(from: date, calendar: calendar) == "2026-02-28")
        #expect(ISODay.adding(days: 1, to: "2026-02-28", calendar: calendar) == "2026-03-01")
    }

    @Test func readsTimestamps() {
        #expect(ISODay.timestamp("2026-10-14T18:15:00.123Z") != nil)
        #expect(ISODay.timestamp("2026-10-14T18:15:00Z") != nil)
        #expect(ISODay.timestamp(nil) == nil)
    }
}

struct APIModelsTests {
    @Test func decodesAPlannerSlotWithMissingArrays() throws {
        let json = #"{"id":"s1","customMeal":"Leftovers","completed":true}"#
        let slot = try JSONDecoder().decode(PlannerSlot.self, from: Data(json.utf8))
        #expect(slot.recipeItems.isEmpty)
        #expect(slot.excludedMembers.isEmpty)
        #expect(slot.title == "Leftovers")
        #expect(slot.completed)
    }

    @Test func householdMembersReadEitherCase() throws {
        let json = #"[{"name":"Ella","date_of_birth":"2014-03-02","avatar_url":"u/ella.jpg"},{"name":"Max","dateOfBirth":"2017-01-09","avatarUrl":"https://x/max.jpg"}]"#
        let members = try JSONDecoder().decode([HouseholdMember].self, from: Data(json.utf8))
        #expect(members[0].dateOfBirth == "2014-03-02")
        #expect(members[0].avatarUrl == "u/ella.jpg")
        #expect(members[1].avatarUrl == "https://x/max.jpg")
    }

    @Test func clearingAFieldSendsNull() throws {
        var update = PlanSlotUpdate(weekStart: "2026-10-11", day: .wednesday, slot: .dinner)
        update.dineOut = .some(nil)
        let json = String(decoding: try JSONEncoder().encode(update), as: UTF8.self)
        #expect(json.contains(#""dineOut":null"#))
        #expect(!json.contains("customMeal"))
    }

    @Test func limitReachedIsRecognized() {
        #expect(APIError(kind: .rejected, status: 403, code: "LIMIT_REACHED").isLimitReached)
        #expect(!APIError(kind: .rejected, status: 403, code: "FORBIDDEN").isLimitReached)
    }
}
