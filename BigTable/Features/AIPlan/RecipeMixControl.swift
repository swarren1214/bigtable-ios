import Foundation
import SwiftUI
import UIKit

/// Where the AI planner's recipes come from.
nonisolated enum AIPlanMixBucket: String, CaseIterable, Identifiable, Sendable {
    /// Recipes the household wrote.
    case mine
    /// Recipes the household favorited (not its own).
    case favorites
    /// Everything else published.
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mine: "My Recipes"
        case .favorites: "Favorites"
        case .other: "Other Recipes"
        }
    }

    var symbol: String {
        switch self {
        case .mine: "person.fill"
        case .favorites: "heart.fill"
        case .other: "books.vertical.fill"
        }
    }

    var color: Color {
        switch self {
        case .mine: Color(hex: 0xD9472B)
        case .favorites: Color(hex: 0xC2185B)
        case .other: Color(hex: 0x0E8A8A)
        }
    }
}

/// The recipe-mix math from the Expo app (`lib/recipe-mix.ts`): three percentages that always
/// add to 100.
nonisolated enum AIPlanMix {
    static func value(_ mix: RecipeMix, _ bucket: AIPlanMixBucket) -> Int {
        switch bucket {
        case .mine: mix.mine
        case .favorites: mix.favorites
        case .other: mix.other
        }
    }

    static func setting(_ mix: RecipeMix, _ bucket: AIPlanMixBucket, to value: Int) -> RecipeMix {
        var copy = mix
        switch bucket {
        case .mine: copy.mine = value
        case .favorites: copy.favorites = value
        case .other: copy.other = value
        }
        return copy
    }

    static func clamp(_ value: Int) -> Int { min(100, max(0, value)) }

    /// Sets one share and rescales the other two in proportion so the total stays 100;
    /// rounding drift goes to the larger of the other two.
    static func rebalance(_ current: RecipeMix, changing bucket: AIPlanMixBucket, to newValue: Int) -> RecipeMix {
        let value = clamp(newValue)
        let others = AIPlanMixBucket.allCases.filter { $0 != bucket }
        let remaining = 100 - value
        let otherTotal = AIPlanMix.value(current, others[0]) + AIPlanMix.value(current, others[1])

        var result = setting(current, bucket, to: value)
        if otherTotal <= 0 {
            let half = Int((Double(remaining) / 2).rounded())
            result = setting(result, others[0], to: half)
            result = setting(result, others[1], to: remaining - half)
        } else {
            let first = clamp(Int((Double(AIPlanMix.value(current, others[0])) / Double(otherTotal) * Double(remaining)).rounded()))
            result = setting(result, others[0], to: first)
            result = setting(result, others[1], to: remaining - first)
        }

        let total = result.mine + result.favorites + result.other
        if total != 100 {
            let target = AIPlanMix.value(result, others[0]) >= AIPlanMix.value(result, others[1]) ? others[0] : others[1]
            result = setting(result, target, to: clamp(AIPlanMix.value(result, target) + (100 - total)))
        }
        return result
    }

    nonisolated struct Preset: Hashable, Sendable {
        var name: String
        var mix: RecipeMix
    }

    static let presets: [Preset] = [
        Preset(name: "Mostly mine", mix: RecipeMix(mine: 50, favorites: 25, other: 25)),
        Preset(name: "Even split", mix: RecipeMix(mine: 34, favorites: 33, other: 33)),
        Preset(name: "Favorites first", mix: RecipeMix(mine: 20, favorites: 60, other: 20)),
        Preset(name: "Try new things", mix: RecipeMix(mine: 15, favorites: 15, other: 70)),
    ]
}

/// Sets how much of the plan comes from your recipes, your favorites and other recipes: a bar
/// showing the split, a slider per source (the other two adjust so it always adds to 100),
/// and a few presets.
struct AIPlanRecipeMixControl: View {
    @Binding var mix: RecipeMix

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            bar

            ForEach(AIPlanMixBucket.allCases) { bucket in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label(bucket.label, systemImage: bucket.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(bucket.color)
                        Spacer()
                        Text("\(AIPlanMix.value(mix, bucket))%")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Slider(value: binding(for: bucket), in: 0...100, step: 5)
                        .tint(bucket.color)
                        .accessibilityLabel(bucket.label)
                        .accessibilityValue("\(AIPlanMix.value(mix, bucket)) percent")
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(AIPlanMix.presets, id: \.name) { preset in
                        let isOn = preset.mix == mix
                        Button {
                            withAnimation(.snappy) { mix = preset.mix }
                        } label: {
                            Text(preset.name)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 32)
                                .foregroundStyle(isOn ? Color.white : Color.primary)
                                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .animation(.snappy, value: mix)
    }

    private var bar: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(AIPlanMixBucket.allCases) { bucket in
                    let share = CGFloat(AIPlanMix.value(mix, bucket)) / 100
                    if share > 0 {
                        Rectangle()
                            .fill(bucket.color.gradient)
                            .frame(width: max(0, proxy.size.width * share - 2))
                    }
                }
            }
        }
        .frame(height: 14)
        .clipShape(Capsule())
        .background(Color(.tertiarySystemFill), in: Capsule())
        .accessibilityElement()
        .accessibilityLabel("Recipe mix")
        .accessibilityValue(AIPlanMixBucket.allCases.map { "\($0.label) \(AIPlanMix.value(mix, $0)) percent" }.joined(separator: ", "))
    }

    private func binding(for bucket: AIPlanMixBucket) -> Binding<Double> {
        Binding(
            get: { Double(AIPlanMix.value(mix, bucket)) },
            set: { newValue in
                mix = AIPlanMix.rebalance(mix, changing: bucket, to: Int(newValue.rounded()))
            }
        )
    }
}
