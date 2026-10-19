import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// Lays chips out in rows, wrapping as needed. `alignment` centers rows (onboarding) or keeps
/// them leading (everywhere else).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var centered = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (centered ? (bounds.width - row.width) / 2 : 0)
            for index in row.indices {
                let size = measure(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// A subview's natural size on one line, narrowed to the row when it's wider than that, so
    /// a long chip wraps inside the row instead of running off the edge.
    private func measure(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = measure(subviews[index], width: width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

extension View {
    /// Shows an error message as an alert; clearing it dismisses the alert.
    func errorAlert(_ message: Binding<String?>, title: String = "Something went wrong") -> some View {
        alert(title, isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

/// A card with a spinner, for content that's loading.
struct LoadingCard: View {
    var title: String = "Loading…"

    var body: some View {
        Card(padding: 24) {
            HStack(spacing: 12) {
                ProgressView()
                Text(title).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Something didn't load: what happened and Try Again.
struct RetryCard: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        Card(padding: 20) {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// "Pro" next to a feature that needs it.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(.tint, in: Capsule())
            .accessibilityLabel("Plus feature")
    }
}

/// Photos picked or taken, made small enough to upload.
enum PhotoTools {
    /// Scales to at most `maxSide` points on the long side and encodes as JPEG.
    static func jpeg(from data: Data, maxSide: CGFloat = 1600, quality: CGFloat = 0.82) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpeg(from: image, maxSide: maxSide, quality: quality)
    }

    static func jpeg(from image: UIImage, maxSide: CGFloat = 1600, quality: CGFloat = 0.82) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Loads a PhotosPicker item as JPEG data.
    static func load(_ item: PhotosPickerItem, maxSide: CGFloat = 1600) async -> Data? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return jpeg(from: data, maxSide: maxSide)
    }
}

/// The camera, for scanning a recipe or a member photo. (PhotosPicker covers the library.)
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

extension AppModel {
    /// The household's people as faces. With a Hearth household, its people (by first name,
    /// which is what a meal's "not eating" list holds), their photos and colors; otherwise the
    /// server's list, each with a stable color by its place.
    var faces: [Face] {
        let household = HearthHouseholdStore.shared
        if household.exists {
            return household.people.map { person in
                Face(id: person.id, name: Self.planName(person), url: person.photo.flatMap { Hearth.photosDirectory?.appending(path: $0).absoluteString }, color: person.color)
            }
        }
        return members.enumerated().map { index, member in
            Face(id: member.id ?? member.name, name: member.name, url: ProfileAvatar.url(for: member.avatarUrl), color: PersonColor.forIndex(index).color)
        }
    }

    /// How someone is named in the plan: their first name.
    static func planName(_ person: HearthMember) -> String {
        person.firstName.isEmpty ? person.trimmedName : person.firstName
    }

    /// How many people eat at home.
    var householdSize: Int {
        let household = HearthHouseholdStore.shared
        return max(household.exists ? household.people.count : members.count, 1)
    }

    /// Everyone's names, for Ask.
    var householdNames: [String] {
        let household = HearthHouseholdStore.shared
        if household.exists { return household.people.map(Self.planName) }
        return members.map(\.name).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func color(forMember name: String) -> Color {
        if let face = faces.first(where: { $0.name == name }) { return face.color }
        let index = members.firstIndex { $0.name == name } ?? 0
        return PersonColor.forIndex(index).color
    }
}

/// "3 days ago", "Just now" for timestamps from the API.
func relativeTime(_ iso: String?) -> String {
    guard let date = ISODay.timestamp(iso) else { return "" }
    if Date.now.timeIntervalSince(date) < 60 { return "Just now" }
    return date.formatted(.relative(presentation: .named))
}
