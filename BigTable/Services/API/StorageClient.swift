import Foundation

/// Uploads photos to Supabase Storage, as the Expo app did: member photos to `member-avatars`,
/// recipe photos to `recipe-images`, each under the signed-in user's id. Returns the public URL
/// the API stores.
nonisolated struct StorageClient: Sendable {
    static let shared = StorageClient()

    nonisolated enum Bucket: String, Sendable {
        case memberAvatars = "member-avatars"
        case recipeImages = "recipe-images"
    }

    var auth: AuthClient = .shared

    /// A member's photo: `<user>/<memberKey>-<time>.jpg`.
    func uploadMemberPhoto(_ jpeg: Data, memberKey: String) async throws -> String {
        let userID = try await self.userID()
        let stamp = Int(Date.now.timeIntervalSince1970 * 1000)
        return try await upload(jpeg, bucket: .memberAvatars, path: "\(userID)/\(memberKey)-\(stamp).jpg", contentType: "image/jpeg")
    }

    /// A recipe's photo: `<user>/recipes/<time>.<ext>`.
    func uploadRecipePhoto(_ data: Data, mimeType: String = "image/jpeg") async throws -> String {
        let userID = try await self.userID()
        let stamp = Int(Date.now.timeIntervalSince1970 * 1000)
        let ext = mimeType.contains("png") ? "png" : mimeType.contains("webp") ? "webp" : "jpg"
        return try await upload(data, bucket: .recipeImages, path: "\(userID)/recipes/\(stamp).\(ext)", contentType: mimeType)
    }

    func publicURL(bucket: Bucket, path: String) -> String {
        AppConfig.supabaseURL.appending(path: "storage/v1/object/public/\(bucket.rawValue)/\(path)").absoluteString
    }

    private func userID() async throws -> String {
        guard let id = await auth.currentSession?.user.id else { throw APIError.signedOut }
        return id
    }

    private func upload(_ data: Data, bucket: Bucket, path: String, contentType: String) async throws -> String {
        var lastError: Error = APIError(kind: .server, status: 503)
        // Two tries, as the Expo app made: uploads on a weak connection often fail once.
        for attempt in 1...2 {
            do {
                let token = try await auth.accessToken()
                var request = URLRequest(url: AppConfig.supabaseURL.appending(path: "storage/v1/object/\(bucket.rawValue)/\(path)"))
                request.httpMethod = "POST"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                request.setValue("true", forHTTPHeaderField: "x-upsert")
                let (body, response) = try await URLSession.shared.upload(for: request, from: data)
                guard let http = response as? HTTPURLResponse else { throw APIError(kind: .server, status: 502) }
                guard (200..<300).contains(http.statusCode) else {
                    let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["message"] as? String
                    throw APIError(kind: http.statusCode >= 500 ? .server : .rejected, status: http.statusCode, message: message ?? "The photo didn't upload.")
                }
                return publicURL(bucket: bucket, path: path)
            } catch {
                lastError = error
                if attempt == 1 { try? await Task.sleep(for: .milliseconds(450)) }
            }
        }
        throw lastError
    }
}
