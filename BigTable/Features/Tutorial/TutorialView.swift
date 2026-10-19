import Foundation
import SwiftUI
import UIKit

/// The tour after a household is set up (and from Profile › Take the Tour): a few pages on the
/// Plan, Recipes, Grocery, the household, Community and Pro. Skip or Done ends it; either way
/// `onFinish` runs once (swiping the sheet away counts too).
struct TutorialView: View {
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var index = 0
    @State private var finished = false
    @State private var showPaywall = false

    private let slides = TutorialSlideContent.all
    private var isLast: Bool { index >= slides.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(index + 1) of \(slides.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Skip") { finish() }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .opacity(isLast ? 0 : 1)
                    .disabled(isLast)
                    .accessibilityLabel("Skip the tour")
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            ProgressView(value: Double(index + 1), total: Double(slides.count))
                .tint(accent)
                .padding(.horizontal, 24)
                .animation(.smooth, value: index)
                .accessibilityHidden(true)

            TabView(selection: $index) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { position, slide in
                    TutorialSlidePage(slide: slide) { showPaywall = true }
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            OnboardingPrimaryButton(title: isLast ? "Done" : "Next") {
                if isLast {
                    finish()
                } else {
                    withAnimation(.smooth) { index += 1 }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
            .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .hearthPaywall(isPresented: $showPaywall, startWith: .app)
        .onDisappear {
            if !finished {
                finished = true
                onFinish()
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
        dismiss()
    }
}

/// One page of the tour.
private struct TutorialSlidePage: View {
    var slide: TutorialSlideContent
    var onUpgrade: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 24)
                ZStack(alignment: .topTrailing) {
                    OnboardingSymbolIcon(symbol: slide.symbol, size: 104)
                    if slide.isPro {
                        ProBadge().offset(x: 14, y: -8)
                    }
                }
                Text(slide.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(slide.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                if slide.isPro && !HearthPurchases.shared.isUnlocked {
                    Button("See Upgrade Options", systemImage: "sparkles", action: onUpgrade)
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The tour's pages, from the Expo app's slides.
struct TutorialSlideContent: Identifiable, Hashable {
    var id: String
    var symbol: String
    var title: String
    var body: String
    var isPro = false

    static var all: [TutorialSlideContent] {
        var slides = [
            TutorialSlideContent(
                id: "welcome",
                symbol: "hand.wave.fill",
                title: "Welcome to BigTable",
                body: "Your household is ready. Here's a quick look at how everything works. It only takes a minute."
            ),
            TutorialSlideContent(
                id: "plan",
                symbol: "calendar",
                title: "Build your week",
                body: "Plan is home base. Tap any breakfast, lunch or dinner to add a recipe, mark a night out, or leave it open. Everyone in the household sees the same plan."
            ),
            TutorialSlideContent(
                id: "recipes",
                symbol: "book.closed.fill",
                title: "Your recipe library",
                body: "Save recipes from the web, snap a cookbook page, or type them in. Add any recipe straight to a meal."
            ),
            TutorialSlideContent(
                id: "grocery",
                symbol: "cart.fill",
                title: "The grocery list, sorted",
                body: "BigTable builds the list from your plan, sorted by aisle. Check things off as you shop and they stay checked for everyone."
            ),
            TutorialSlideContent(
                id: "household",
                symbol: "person.2.fill",
                title: "Your household, your way",
                body: "Add people, ages, likes, dislikes and dietary restrictions in Profile. BigTable uses them to size portions and suggest recipes."
            ),
        ]
        if AppConfig.socialEnabled {
            slides.append(TutorialSlideContent(
                id: "social",
                symbol: "heart.fill",
                title: "See what others are cooking",
                body: "Follow other households in Community to browse their recipes, and share your own favorites when you're ready."
            ))
        }
        slides += [
            TutorialSlideContent(
                id: "pro-planning",
                symbol: "sparkles",
                title: "Let AI plan your week",
                body: "BigTable Plus plans a whole week of meals in seconds, around everyone's restrictions, preferences and what's already planned.",
                isPro: true
            ),
            TutorialSlideContent(
                id: "pro-grocery",
                symbol: "wand.and.stars",
                title: "Smarter shopping lists",
                body: "With Plus, AI builds the grocery list for you: grouped by aisle, with amounts filled in and a cost estimate.",
                isPro: true
            ),
            TutorialSlideContent(
                id: "done",
                symbol: "checkmark.seal.fill",
                title: "You're all set!",
                body: "Start planning. You can take this tour again from Profile anytime."
            ),
        ]
        return slides
    }
}
