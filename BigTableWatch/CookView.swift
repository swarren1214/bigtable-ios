import SwiftUI

/// Cooking from the wrist: one step per page (turn the Digital Crown or swipe), the step's timer
/// when it names a time, and Next.
struct CookView: View {
    let recipe: WatchRecipe

    @Environment(CookTimer.self) private var timer
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int? = 0
    @State private var showsTimer = false

    var body: some View {
        let current = min(index ?? 0, max(recipe.steps.count - 1, 0))
        TabView(selection: $index) {
            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { number, step in
                StepPage(step: step, number: number, count: recipe.steps.count)
                    .tag(Optional(number))
            }
        }
        .tabViewStyle(.verticalPage)
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if let seconds = recipe.steps[safe: current]?.timerSeconds {
                    Button {
                        if !(timer.isActive && timer.recipe == recipe.title && timer.label == Self.label(for: recipe.steps[current], number: current)) {
                            timer.start(seconds: seconds, label: Self.label(for: recipe.steps[current], number: current), recipe: recipe.title)
                        }
                        showsTimer = true
                    } label: {
                        Label(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)), systemImage: "timer")
                    }
                    .accessibilityLabel("Start a \(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))) timer")
                }
                Spacer()
                if current < recipe.steps.count - 1 {
                    Button {
                        withAnimation { index = current + 1 }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    // Tinted glass with a white symbol: the bar's own button shape, in the
                    // app's color (not a filled button drawn inside the bar's glass).
                    .buttonStyle(.glassProminent)
                    .tint(WatchTheme.accent)
                    .accessibilityLabel("Next step")
                } else {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(WatchTheme.accent)
                    .accessibilityLabel("Done cooking")
                }
            }
        }
        .navigationDestination(isPresented: $showsTimer) { TimerView() }
    }

    /// "2. In a large bowl…" → "In a large bowl…": the page already says which step it is.
    static func withoutNumber(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\s*(step\s*)?\d+\s*[.):-]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// What the timer is for: the step's first word when it's a verb-like word ("Simmer",
    /// "Bake"), otherwise "Step 5".
    static func label(for step: WatchStep, number: Int) -> String {
        let first = withoutNumber(step.text).split(separator: " ").first.map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
        if first.count >= 3, first.count <= 12, first.allSatisfy(\.isLetter) {
            return first.prefix(1).uppercased() + first.dropFirst().lowercased()
        }
        return "Step \(number + 1)"
    }
}

private struct StepPage: View {
    let step: WatchStep
    let number: Int
    let count: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Step \(number + 1) of \(count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                // How far along: one segment per step.
                HStack(spacing: 3) {
                    ForEach(0..<count, id: \.self) { segment in
                        Capsule()
                            .fill(segment <= number ? WatchTheme.accent : Color.white.opacity(0.2))
                            .frame(height: 3)
                    }
                }
                .accessibilityHidden(true)
                Text(CookView.withoutNumber(step.text))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
