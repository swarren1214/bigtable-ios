import SwiftUI
import UIKit

/// The layout every onboarding screen shares, the same as Suffice's and Hearken's: an icon, a
/// large title and a one-line promise centered at the top, the screen's content under them in
/// a readable column, and the buttons pinned to the bottom.
struct OnboardingPage<Icon: View, Content: View, Controls: View>: View {
    var title: String
    var subtitle: String
    /// "2 of 3" dots above the icon; nil hides them.
    var step: (number: Int, of: Int)?
    @ViewBuilder var icon: (_ isShort: Bool) -> Icon
    @ViewBuilder var content: (_ isShort: Bool) -> Content
    @ViewBuilder var controls: (_ isShort: Bool) -> Controls

    /// The screen's height, to fit short screens (iPhone SE).
    @State private var height: CGFloat = 900

    private var isShort: Bool { height < 760 }
    static var columnWidth: CGFloat { 480 }

    init(
        title: String,
        subtitle: String,
        step: (number: Int, of: Int)? = nil,
        @ViewBuilder icon: @escaping (_ isShort: Bool) -> Icon,
        @ViewBuilder content: @escaping (_ isShort: Bool) -> Content,
        @ViewBuilder controls: @escaping (_ isShort: Bool) -> Controls
    ) {
        self.title = title
        self.subtitle = subtitle
        self.step = step
        self.icon = icon
        self.content = content
        self.controls = controls
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: isShort ? 10 : 14) {
                    if let step {
                        StepDots(number: step.number, of: step.of)
                            .padding(.bottom, isShort ? 4 : 10)
                    }
                    icon(isShort)
                    Text(title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .padding(.top, isShort ? 2 : 6)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    content(isShort)
                        .padding(.top, isShort ? 20 : 32)
                }
                .padding(.horizontal, 28)
                .padding(.top, isShort ? 24 : (step == nil ? 64 : 40))
                .padding(.bottom, isShort ? 16 : 32)
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .scrollDismissesKeyboard(.interactively)

            controls(isShort)
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: Self.columnWidth)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
}

/// The big accent button at the bottom of an onboarding screen.
struct OnboardingPrimaryButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
}

/// The app icon, from Icon Composer's light and dark PNG exports (BigTableMark in the asset
/// catalog; re-export them when the icon changes). The welcome screen, as in Caloma and Suffice.
struct AppIconBadge: View {
    var size: CGFloat = 92
    @Environment(\.accent) private var accent

    var body: some View {
        Image("BigTableMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: accent.opacity(0.3), radius: 15, y: 10)
            .accessibilityHidden(true)
    }
}

/// An onboarding screen's icon: an SF Symbol on the accent, rounded-square shape.
struct OnboardingSymbolIcon: View {
    var symbol: String
    var size: CGFloat = 92
    @Environment(\.accent) private var accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [accent.mix(with: .white, by: 0.15), accent.mix(with: .black, by: 0.2)], startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: size * 0.2237, style: .continuous)
            )
            .shadow(color: accent.opacity(0.3), radius: 15, y: 10)
            .accessibilityHidden(true)
    }
}

/// A row in an onboarding list: accent symbol, bold title, a line of detail.
struct OnboardingFeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where you are in onboarding: a dot per step, the current one stretched.
private struct StepDots: View {
    var number: Int
    var of: Int
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(of, 1), id: \.self) { index in
                Capsule()
                    .fill(index == number ? accent : Color(.systemGray4))
                    .frame(width: index == number ? 20 : 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number) of \(of)")
    }
}
