import Foundation
import OSLog
import Security

/// A signed-in Supabase session: the same accounts the Expo app used (email and password, or
/// Sign in with Apple), so beta users sign in and find their household.
nonisolated struct AuthSession: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Seconds since 1970.
    var expiresAt: Double
    var user: AuthUser

    var isExpiringSoon: Bool { Date.now.timeIntervalSince1970 > expiresAt - 60 }
}

nonisolated struct AuthUser: Codable, Sendable, Equatable {
    var id: String
    var email: String?
    var fullName: String?
}

nonisolated enum AuthError: Error, LocalizedError, Equatable, Sendable {
    case offline
    case unreachable
    case invalidCredentials
    case emailNotConfirmed
    case userExists
    case weakPassword(String)
    case rateLimited
    case rejected(String)
    case signedOut

    var errorDescription: String? {
        switch self {
        case .offline: "You're offline. Connect to the internet and try again."
        case .unreachable: "BigTable can't reach its server right now. Try again in a moment."
        case .invalidCredentials: "That email and password don't match. Try again or reset your password."
        case .emailNotConfirmed: "Check your email and tap the confirmation link, then sign in."
        case .userExists: "There's already an account with that email. Sign in instead."
        case .weakPassword(let message): message
        case .rateLimited: "Too many tries just now. Wait a minute and try again."
        case .rejected(let message): message
        case .signedOut: "Your session ended. Sign in again."
        }
    }
}

/// Talks to Supabase Auth (GoTrue) over REST and keeps the session in the Keychain.
///
/// - A token is reused until a minute before it expires, then refreshed.
/// - Only one refresh runs at a time; everyone else waits for it (two refreshes would spend
///   the same refresh token twice, and Supabase rejects the second).
/// - The session is dropped only when Supabase rejects the refresh token, never because the
///   network failed.
actor AuthClient {
    nonisolated static let shared = AuthClient()

    private let baseURL = AppConfig.supabaseURL.appending(path: "auth/v1")
    private let anonKey = AppConfig.supabaseAnonKey
    private let urlSession: URLSession
    private var session: AuthSession?
    private var refreshTask: Task<AuthSession, Error>?
    private let store = KeychainSessionStore(account: "supabase-session")
    nonisolated private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "auth")

    /// Called (on the main actor) whenever the session changes: signed in, refreshed, signed out.
    private var onChange: (@Sendable (AuthSession?) -> Void)?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        urlSession = URLSession(configuration: configuration)
        // Screenshot mode (Debug) is signed in as its demo organizer, never the saved session.
        session = ScreenshotMode.isOn ? ScreenshotMode.session : store.load()
    }

    func observe(_ handler: @escaping @Sendable (AuthSession?) -> Void) {
        onChange = handler
        handler(session)
    }

    var currentSession: AuthSession? { session }

    // MARK: Tokens

    /// The access token for an API call, refreshed first if it's about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = session else { throw AuthError.signedOut }
        if !forceRefresh && !current.isExpiringSoon { return current.accessToken }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> AuthSession {
        if let refreshTask { return try await refreshTask.value }
        guard let current = session else { throw AuthError.signedOut }
        let task = Task<AuthSession, Error> {
            try await self.tokenRequest(grant: "refresh_token", body: ["refresh_token": current.refreshToken])
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            set(fresh)
            return fresh
        } catch AuthError.invalidCredentials {
            // Supabase rejected the refresh token: the session is over.
            set(nil)
            throw AuthError.signedOut
        } catch let error as AuthError where error == .signedOut {
            set(nil)
            throw error
        }
    }

    // MARK: Signing in

    func signIn(email: String, password: String) async throws {
        let session = try await tokenRequest(grant: "password", body: ["email": email, "password": password])
        set(session)
    }

    /// Creates an account. Returns true when signed in right away, false when Supabase wants
    /// the email confirmed first.
    func signUp(email: String, password: String, fullName: String) async throws -> Bool {
        var components = URLComponents(url: baseURL.appending(path: "signup"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "redirect_to", value: AppConfig.authRedirect)]
        let body: [String: Any] = ["email": email, "password": password, "data": ["full_name": fullName]]
        let data = try await send(url: components.url!, method: "POST", json: body)
        if let session = try? Self.decodeSession(data) {
            set(session)
            return true
        }
        return false
    }

    /// Sign in with Apple: the identity token from AuthenticationServices, and the raw nonce
    /// whose SHA-256 went in the request.
    func signInWithApple(idToken: String, nonce: String?, fullName: String?) async throws {
        var body: [String: Any] = ["provider": "apple", "id_token": idToken]
        if let nonce { body["nonce"] = nonce }
        var session = try await tokenRequest(grant: "id_token", body: body)
        set(session)
        if let fullName, !fullName.isEmpty {
            // Apple only shares the name the first time, so keep it on the account.
            try? await updateUser(["data": ["full_name": fullName]])
            session.user.fullName = fullName
            set(session)
        }
    }

    func sendPasswordReset(email: String) async throws {
        var components = URLComponents(url: baseURL.appending(path: "recover"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "redirect_to", value: AppConfig.authRedirect)]
        _ = try await send(url: components.url!, method: "POST", json: ["email": email])
    }

    /// bigtable://auth#access_token=…&refresh_token=…&type=recovery|signup, from the emails.
    /// Returns the link's type ("recovery" means: ask for a new password).
    func handleRedirect(_ url: URL) async throws -> String? {
        let fragment = url.fragment ?? url.query ?? ""
        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        if let message = values["error_description"] { throw AuthError.rejected(message.replacingOccurrences(of: "+", with: " ")) }
        guard let access = values["access_token"], let refreshToken = values["refresh_token"] else { return nil }
        let expiresIn = Double(values["expires_in"] ?? "3600") ?? 3600
        let user = try await fetchUser(accessToken: access)
        set(AuthSession(accessToken: access, refreshToken: refreshToken, expiresAt: Date.now.timeIntervalSince1970 + expiresIn, user: user))
        return values["type"]
    }

    func updatePassword(_ password: String) async throws {
        try await updateUser(["password": password])
    }

    func updateFullName(_ name: String) async throws {
        try await updateUser(["data": ["full_name": name]])
        if var current = session {
            current.user.fullName = name
            set(current)
        }
    }

    private func updateUser(_ body: [String: Any]) async throws {
        let token = try await accessToken()
        _ = try await send(url: baseURL.appending(path: "user"), method: "PUT", json: body, bearer: token)
    }

    func signOut() async {
        if let token = session?.accessToken {
            _ = try? await send(url: baseURL.appending(path: "logout"), method: "POST", json: [:], bearer: token)
        }
        set(nil)
    }

    /// Forgets the session without telling Supabase (after deleting the account).
    func clear() { set(nil) }

    // MARK: Plumbing

    private func set(_ new: AuthSession?) {
        session = new
        // Screenshot mode (Debug) keeps its demo session out of the Keychain.
        if !ScreenshotMode.isOn {
            if let new { store.save(new) } else { store.delete() }
        }
        onChange?(new)
    }

    private func tokenRequest(grant: String, body: [String: Any]) async throws -> AuthSession {
        var components = URLComponents(url: baseURL.appending(path: "token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        let data = try await send(url: components.url!, method: "POST", json: body)
        return try Self.decodeSession(data)
    }

    private func fetchUser(accessToken: String) async throws -> AuthUser {
        let data = try await send(url: baseURL.appending(path: "user"), method: "GET", json: nil, bearer: accessToken)
        let raw = try JSONDecoder().decode(RawUser.self, from: data)
        return raw.user
    }

    private func send(url: URL, method: String, json: [String: Any]?, bearer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer ?? anonKey)", forHTTPHeaderField: "Authorization")
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .networkConnectionLost:
                throw AuthError.offline
            default:
                throw AuthError.unreachable
            }
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.rejected("Unexpected response") }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data)
        }
        return data
    }

    nonisolated private static func error(status: Int, data: Data) -> AuthError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (body["error_code"] as? String) ?? (body["error"] as? String) ?? ""
        let message = (body["msg"] as? String) ?? (body["error_description"] as? String) ?? (body["message"] as? String) ?? "Something went wrong. Try again."
        switch (status, code) {
        case (429, _): return .rateLimited
        case (_, "invalid_credentials"), (_, "invalid_grant"), (_, "refresh_token_not_found"), (_, "refresh_token_already_used"):
            return .invalidCredentials
        case (_, "email_not_confirmed"): return .emailNotConfirmed
        case (_, "user_already_exists"), (_, "email_exists"): return .userExists
        case (_, "weak_password"): return .weakPassword(message)
        default:
            if message.lowercased().contains("invalid login") { return .invalidCredentials }
            return .rejected(message)
        }
    }

    nonisolated private struct RawSession: Decodable {
        var access_token: String
        var refresh_token: String
        var expires_in: Double?
        var expires_at: Double?
        var user: RawUser
    }

    nonisolated private struct RawUser: Decodable {
        var id: String
        var email: String?
        var user_metadata: [String: JSONValue]?

        var user: AuthUser {
            AuthUser(id: id, email: email, fullName: user_metadata?["full_name"]?.string)
        }
    }

    nonisolated private static func decodeSession(_ data: Data) throws -> AuthSession {
        let raw = try JSONDecoder().decode(RawSession.self, from: data)
        let expiresAt = raw.expires_at ?? (Date.now.timeIntervalSince1970 + (raw.expires_in ?? 3600))
        return AuthSession(accessToken: raw.access_token, refreshToken: raw.refresh_token, expiresAt: expiresAt, user: raw.user.user)
    }
}

/// The session as one Keychain item, readable after first unlock (background refreshes).
nonisolated struct KeychainSessionStore: Sendable {
    var account: String
    private let service = "com.stephenwarren.bigtable.auth"

    func load() -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
