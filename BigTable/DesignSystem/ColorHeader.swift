import SwiftUI

// The color header shared by all five Hearth apps (it started in Suffice): the app's color
// across the top of a tab, under a large white title, fading into the gray background so
// the cards below sit mostly on gray.

/// The app's color at the top of a tab, fading to nothing halfway down the screen on iPhone, 40% of the way on iPad.
/// Fixed behind the scroll view.
struct HeaderGradient: View {
    var color: Color = Brand.defaultAccent
    /// How far down the screen the color reaches before it's gone, as a share of the screen's
    /// height: half on iPhone, 40% on iPad.
    var fraction: CGFloat?

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        // On iPhone the color holds longer before it fades (eased), so it reads stronger in the
        // shorter space; on iPad, an even fade from the very top to the very bottom.
        let curve = sizeClass == .compact ? Self.phoneCurve : Self.evenCurve
        let start = color
        let end = color.mix(with: .white, by: 0.12)
        GeometryReader { geo in
            LinearGradient(
                stops: curve.map { point in
                    Gradient.Stop(color: start.mix(with: end, by: point.location).opacity(point.opacity), location: point.location)
                },
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: geo.size.width, height: geo.size.height * (fraction ?? (sizeClass == .compact ? 0.5 : 0.4)))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// The color's strength at points down the gradient (0 = top, 1 = where it's gone).
    private static let phoneCurve: [(location: Double, opacity: Double)] = [
        (0, 1), (0.3, 0.88), (0.6, 0.5), (0.85, 0.15), (1, 0),
    ]
    private static let evenCurve: [(location: Double, opacity: Double)] = [(0, 1), (1, 0)]
}

/// The big white title at the top of a color-header screen, with an optional line under it
/// (a date, a count) and an optional figure on the right.
struct HeaderTitle: View {
    @Environment(\.colorScheme) private var colorScheme
    var title: String
    var subtitle: String?
    var trailing: String?

    init(_ title: String, subtitle: String? = nil, trailing: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .opacity(0.85)
            }
        }
        // A touch softer in Light Mode, where pure white over the lighter color is glaring.
        .foregroundStyle(.white.opacity(colorScheme == .light ? 0.88 : 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

extension View {
    /// Puts a scroll view under the color header: the gradient behind it, the gray below, and
    /// a white navigation bar. The navigation title is set for the back button and VoiceOver,
    /// but the visible title is drawn large in the content with `HeaderTitle`.
    func colorHeader(_ title: String, color: Color = Brand.defaultAccent) -> some View {
        self
            .background(alignment: .top) { HeaderGradient(color: color) }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                // The title is drawn large in the content, as in Suffice.
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
    }
}
