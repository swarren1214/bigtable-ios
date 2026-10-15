import Foundation
import SwiftUI
import UIKit

// The pieces every BigTable screen is built from, matching the BigTable designs and the rest
// of the suite: grouped-gray screens, white 22 pt cards, tinted icon tiles, people's avatars,
// capsule chips, and round checks.

/// A white card with the designs' 22 pt corners.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

/// Rows inside a white card, with hairlines between them.
struct CardList<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    var items: Data
    var inset: CGFloat = 62
    @ViewBuilder var row: (Data.Element) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    Divider().padding(.leading, inset)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

/// "Today", "Ingredients": the 22 pt section titles, with an optional control on the right.
struct SectionTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
                .font(.subheadline)
        }
        .padding(.horizontal, 4)
    }
}

/// A tab's screen: a large title, then cards in a readable column (wider on iPad).
struct BigTableScreen<Content: View>: View {
    static var readableWidth: CGFloat { 860 }

    var title: String
    var maxWidth: CGFloat = BigTableScreen.readableWidth
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// A rounded square with an SF Symbol on a pale wash of its color.
struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 34
    var filled = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(filled ? Color.white : color)
            .frame(width: size, height: size)
            .background(filled ? color : color.opacity(0.15), in: .rect(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A person's circle: their photo (from the API's URL, or picked data), or their initial on a
/// gradient of their color.
struct MemberAvatar: View {
    var name: String
    var color: Color
    var url: String?
    var photo: Data?
    var size: CGFloat = 36

    init(name: String, color: Color, url: String? = nil, photo: Data? = nil, size: CGFloat = 36) {
        self.name = name
        self.color = color
        self.url = url
        self.photo = photo
        self.size = size
    }

    var body: some View {
        Group {
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let url, let link = URL(string: url) {
                AsyncImage(url: link) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initial
                    }
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initial: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(colors: [color, color.mix(with: .black, by: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// Someone in a face pile.
struct Face: Identifiable, Hashable {
    var id: String
    var name: String
    var url: String?
    var color: Color
}

/// Overlapping faces: who's eating. Skipped people fade.
struct FacePile: View {
    var faces: [Face]
    var skipped: Set<String> = []
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: -size * 0.24) {
            ForEach(faces) { face in
                MemberAvatar(name: face.name, color: face.color, url: face.url, size: size)
                    .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                    .opacity(skipped.contains(face.name) || skipped.contains(face.id) ? 0.3 : 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A capsule for picking a person or a filter, filled with its color when selected.
struct Chip: View {
    var title: String
    var color: Color
    var isOn: Bool
    var showsDot = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showsDot {
                    Circle()
                        .fill(isOn ? Color.white : color)
                        .frame(width: 8, height: 8)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? AnyShapeStyle(color) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A small colored label: "Peanuts", "Leftovers", "Freezer-friendly".
struct TagLabel: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .rect(cornerRadius: 6))
    }
}

/// The round check on a meal or grocery row: empty, or filled with a check.
struct RoundCheck: View {
    var isOn: Bool
    var color: Color
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color(.systemGray3), lineWidth: 2)
                .opacity(isOn ? 0 : 1)
            Circle()
                .fill(color)
                .opacity(isOn ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(.white)
                .opacity(isOn ? 1 : 0)
                .scaleEffect(isOn ? 1 : 0.4)
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.35, bounce: 0.5), value: isOn)
    }
}

/// A recipe's photo (from its URL, or picked data), or a warm tile with a plate when it has
/// none.
struct RecipePhoto: View {
    var url: String?
    var data: Data?
    var cornerRadius: CGFloat = 16
    var symbolSize: CGFloat = 28

    init(url: String? = nil, data: Data? = nil, cornerRadius: CGFloat = 16, symbolSize: CGFloat = 28) {
        self.url = url
        self.data = data
        self.cornerRadius = cornerRadius
        self.symbolSize = symbolSize
    }

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if ScreenshotMode.isOn, let url, let art = ScreenshotArt(url: url) {
                // Screenshot mode (Debug): demo recipes are drawn here, not downloaded.
                art
            } else if let url, let link = URL(string: url) {
                AsyncImage(url: link) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "fork.knife")
            .font(.system(size: symbolSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.recipeTile)
    }
}

/// An empty state: a symbol, a line, and a message.
struct EmptyCard: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        Card(padding: 24) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// A row that links somewhere: tinted icon, title, detail and a chevron. Home's "Grocery
/// List" and "meals to fill" cards.
struct LinkCard: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}
