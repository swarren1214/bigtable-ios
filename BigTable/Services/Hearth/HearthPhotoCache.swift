import Foundation
import Observation
import UIKit

/// Photos the other Hearth apps (Caloma, Suffice, Sated…) have of people in the household, for
/// members with no photo in BigTable. `MemberAvatar` asks by name.
///
/// Images are decoded once per name and kept until another app's family or photos change
/// (`Hearth.didChange`); BigTable's own writes post the same notification, so the cache is
/// emptied only when something it reads actually changed.
@MainActor
@Observable
final class HearthPhotoCache {
    static let shared = HearthPhotoCache()

    /// Bumped when the other apps' photos change, so avatars showing them redraw.
    private var generation = 0
    @ObservationIgnored private var images: [String: UIImage] = [:]
    @ObservationIgnored private var misses: Set<String> = []
    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        guard !ScreenshotMode.isOn else { return }
        Hearth.startObservingChanges()
        signature = Self.currentSignature()
        observer = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HearthPhotoCache.shared.refreshIfChanged() }
        }
    }

    /// Another Hearth app's photo of the person with this name, or nil.
    func image(forName name: String) -> UIImage? {
        _ = generation
        guard !ScreenshotMode.isOn else { return nil }
        let key = HearthNames.normalized(name)
        guard !key.isEmpty else { return nil }
        if let image = images[key] { return image }
        if misses.contains(key) { return nil }
        if let data = Hearth.sharedPhoto(forName: key, excluding: .bigtable), let image = UIImage(data: data) {
            images[key] = image
            return image
        }
        misses.insert(key)
        return nil
    }

    /// Empties the cache when the other apps' families or photos changed.
    func refreshIfChanged() {
        guard !ScreenshotMode.isOn else { return }
        let current = Self.currentSignature()
        guard current != signature else { return }
        signature = current
        images = [:]
        misses = []
        generation += 1
    }

    /// The other apps' families (when each was written) and their photo files (when each was
    /// last modified): cheap to read, and different whenever a photo could have changed.
    private static func currentSignature() -> String {
        let folder = Hearth.photosDirectory
        var parts: [String] = []
        for family in Hearth.readAll(HearthFamily.self) where family.app != .bigtable {
            parts.append("\(family.app.rawValue)@\(family.updatedAt.timeIntervalSince1970)")
            for member in family.value.members {
                guard let photo = member.photo, let folder else { continue }
                let url = folder.appending(path: photo, directoryHint: .notDirectory)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                parts.append("\(photo)@\(modified?.timeIntervalSince1970 ?? 0)")
            }
        }
        return parts.joined(separator: "|")
    }
}
