import Foundation

/// Photos stored on the server (Community profiles, and household photos from before the
/// household moved to HearthKit).
nonisolated enum ProfileAvatar {
    static let publicPrefix = "/storage/v1/object/public/member-avatars/"

    /// A URL `MemberAvatar` can load.
    static func url(for stored: String?) -> String? {
        guard let value = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("http") { return value }
        return StorageClient.shared.publicURL(bucket: .memberAvatars, path: value)
    }

    /// What to save for an uploaded photo's public URL: its object path, as the Expo app did,
    /// so both apps read it.
    static func storedValue(forUploadedURL url: String) -> String {
        guard let range = url.range(of: publicPrefix) else { return url }
        let rest = String(url[range.upperBound...])
        let path = rest.split(separator: "?").first.map(String.init) ?? rest
        let decoded = path.removingPercentEncoding ?? path
        return decoded.isEmpty ? url : decoded
    }
}
