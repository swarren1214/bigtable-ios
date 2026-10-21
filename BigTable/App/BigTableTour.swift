import SwiftUI

/// BigTable's stops on the shared tour (HearthTour.swift): Plan, Recipes, Grocery, Community and
/// Search. It replaces the old slide tutorial. It shows once for a new organizer and again from
/// Profile › Take the Tour. Screens mark what each step points at with `.hearthTourTarget(_:)`.
enum BigTableTour {
    static let plan = "plan"
    static let recipes = "recipes"
    static let grocery = "grocery"
    static let community = "community"
    static let search = "search"

    static var steps: [HearthTourStep] {
        var steps = [
            HearthTourStep(plan, title: "Plan", message: "Your family's week of meals. Tap a day to add dinner, or let BigTable plan the whole week around everyone's tastes and allergies.", symbol: "calendar", color: .orange),
            HearthTourStep(recipes, title: "Recipes", message: "Every recipe you've saved, imported or written. Filter by tag, and open one to cook from it or put it on the plan.", symbol: "book.closed", color: .green),
            HearthTourStep(grocery, title: "Grocery", message: "One list for the household, made from the week's plan. Check things off as you shop, and keep track of the pantry.", symbol: "cart", color: .blue),
        ]
        if AppConfig.socialEnabled {
            steps.append(HearthTourStep(community, title: "Community", message: "Recipes other families share. Follow the cooks you like and save their recipes to your own.", symbol: "person.2", color: .purple))
        }
        steps.append(HearthTourStep(search, title: "Search", message: "Find any recipe by name, ingredient or tag.", symbol: "magnifyingglass", color: .pink))
        return steps
    }

    static func tab(for step: HearthTourStep) -> AppTab {
        switch step.id {
        case recipes: .recipes
        case grocery: .grocery
        case community: .community
        case search: .search
        default: .plan
        }
    }
}
