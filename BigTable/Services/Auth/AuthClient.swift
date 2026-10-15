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
    /// Supabase's anonymous users. BigTable never signs in anonymously, but such a session is
    /// never shared with the other Hearth apps.
    var isAnonymous: Bool? = nil
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
/// - One sign-in for every Hearth app (BigTable, Suffice, Sated sign in to the same Supabase
///   project): the session is shared through `HearthAccounts` (see `HearthSharedSession` in
///   HearthShared.swift for the rules). BigTable adopts the shared session when it has none,
///   uses a newer one another app refreshed instead of spending its own refresh token, saves
///   its own after signing in or refreshing, and follows other apps signing out or switching
///   accounts. Off in screenshot mode.
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

    /// The user whose session BigTable last saw in (or saved to) the shared sign-in. Only then
    /// does a missing shared session mean "signed out in another app" (and not, say, a shared
    /// Keychain that isn't working).
    private var sharedUserID: String?
    /// The session came from another app, which doesn't share the user's name: load it.
    private var needsUserDetails = false
    private var hearthObserver: (any NSObjectProtocol)?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        urlSession = URLSession(configuration: configuration)
        // Screenshot mode (Debug) is signed in as its demo organizer, never the saved session.
        if ScreenshotMode.isOn {
            session = ScreenshotMode.session
            return
        }
        let local = store.load()
        let shared = HearthAccounts.session()
        let resolved = Self.reconcile(local: local, shared: shared)
        session = resolved
        if let resolved {
            if resolved != local { store.save(resolved) }
            if resolved.user.id != local?.user.id { needsUserDetails = true }
            // Shares BigTable's session when there's none yet (or this one is newer).
            Self.share(resolved)
            if HearthAccounts.session()?.userID == resolved.user.id { sharedUserID = resolved.user.id }
        }
    }

    func observe(_ handler: @escaping @Sendable (AuthSession?) -> Void) {
        onChange = handler
        handler(session)
        startFollowingSharedSession()
        if needsUserDetails {
            Task { await self.loadUserDetails() }
        }
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
        guard var current = session else { throw AuthError.signedOut }
        // Another Hearth app may already have refreshed this session (spending the refresh
        // token BigTable holds): use theirs, and refresh only if it's about to expire too.
        if let adopted = newerSharedSession(than: current) {
            set(adopted, share: false)
            if !adopted.isExpiringSoon { return adopted }
            current = adopted
        }
        let refreshToken = current.refreshToken
        let task = Task<AuthSession, Error> {
            try await self.tokenRequest(grant: "refresh_token", body: ["refresh_token": refreshToken])
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            set(fresh)
            return fresh
        } catch AuthError.invalidCredentials {
            // Another app may have spent the token while this request was on its way.
            if let adopted = newerSharedSession(than: current) {
                set(adopted, share: false)
                return adopted
            }
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
    /// whose SHA-256 went in the request. `fallbackName` is the name another Hearth app got from
    /// Apple for this Apple ID, used only when Apple didn't send one and the account has none.
    func signInWithApple(idToken: String, nonce: String?, fullName: String?, fallbackName: String? = nil) async throws {
        var body: [String: Any] = ["provider": "apple", "id_token": idToken]
        if let nonce { body["nonce"] = nonce }
        var session = try await tokenRequest(grant: "id_token", body: body)
        set(session)
        var fullName = fullName
        if fullName?.isEmpty ?? true, (session.user.fullName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            fullName = fallbackName
        }
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

    /// Signs out here and in every other Hearth app on this device.
    func signOut() async {
        if let token = session?.accessToken {
            _ = try? await send(url: baseURL.appending(path: "logout"), method: "POST", json: [:], bearer: token)
        }
        set(nil)
        if !ScreenshotMode.isOn {
            sharedUserID = nil
            HearthAccounts.signOutEverywhere()
        }
    }

    /// Forgets the session without telling Supabase (the API said it's over, or after deleting
    /// the account). `everywhere` also signs the other Hearth apps out of the same account.
    func clear(everywhere: Bool = false) {
        let userID = session?.user.id
        set(nil)
        if everywhere, !ScreenshotMode.isOn, let userID, HearthAccounts.session()?.userID == userID {
            sharedUserID = nil
            HearthAccounts.signOutEverywhere()
        }
    }

    // MARK: One sign-in for every Hearth app

    /// Follows the shared sign-in when another app changes it: signs out when it signed out,
    /// switches when it signed in as someone else, and picks up tokens it refreshed. Called on
    /// `Hearth.didChange` and when the app becomes active. BigTable's own writes post the same
    /// notification, so this only acts on a difference.
    func followSharedSession() async {
        guard !ScreenshotMode.isOn, refreshTask == nil else { return }
        let shared = HearthAccounts.session()
        guard let current = session else {
            // Signed out here, signed in elsewhere: use that account.
            if let shared {
                sharedUserID = shared.userID
                set(Self.adopting(shared), share: false)
                await loadUserDetails()
            }
            return
        }
        guard let shared else {
            // Gone from the shared sign-in after BigTable saw it there: signed out elsewhere.
            if sharedUserID == current.user.id {
                sharedUserID = nil
                set(nil)
            }
            return
        }
        if shared.userID == current.user.id {
            sharedUserID = shared.userID
            if let adopted = newerSharedSession(than: current) { set(adopted, share: false) }
            return
        }
        // Another app signed in as someone else: sign out of this account first, so every
        // screen starts over, then use theirs.
        sharedUserID = shared.userID
        set(nil)
        set(Self.adopting(shared), share: false)
        await loadUserDetails()
    }

    private func startFollowingSharedSession() {
        guard !ScreenshotMode.isOn, hearthObserver == nil else { return }
        Hearth.startObservingChanges()
        hearthObserver = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { _ in
            Task { await AuthClient.shared.followSharedSession() }
        }
    }

    /// The name (and email) of a session taken from another app, which shares only the tokens.
    private func loadUserDetails() async {
        needsUserDetails = false
        guard let token = try? await accessToken(),
              let user = try? await fetchUser(accessToken: token),
              var current = session, current.user.id == user.id else { return }
        guard current.user != user else { return }
        current.user = user
        set(current, share: false)
    }

    /// The shared session, when another app refreshed this user's session after BigTable did.
    private func newerSharedSession(than current: AuthSession) -> AuthSession? {
        guard !ScreenshotMode.isOn,
              let shared = HearthAccounts.session(),
              shared.userID == current.user.id,
              shared.refreshToken != current.refreshToken,
              shared.expiresAt > current.expiresAt else { return nil }
        sharedUserID = shared.userID
        var adopted = current
        adopted.accessToken = shared.accessToken
        adopted.refreshToken = shared.refreshToken
        adopted.expiresAt = shared.expiresAt
        if let email = shared.email { adopted.user.email = email }
        return adopted
    }

    /// Which session to use at launch: BigTable's own, or the shared one when BigTable has none,
    /// it's for someone else (the latest sign-in on this device wins), or it's newer.
    nonisolated private static func reconcile(local: AuthSession?, shared: HearthSharedSession?) -> AuthSession? {
        guard let shared else { return local }
        guard var local else { return adopting(shared) }
        guard local.user.id == shared.userID else { return adopting(shared) }
        if shared.refreshToken != local.refreshToken, shared.expiresAt > local.expiresAt {
            local.accessToken = shared.accessToken
            local.refreshToken = shared.refreshToken
            local.expiresAt = shared.expiresAt
            if let email = shared.email { local.user.email = email }
        }
        return local
    }

    /// A session from the shared sign-in. Its name loads afterwards (`loadUserDetails`).
    nonisolated private static func adopting(_ shared: HearthSharedSession) -> AuthSession {
        AuthSession(
            accessToken: shared.accessToken,
            refreshToken: shared.refreshToken,
            expiresAt: shared.expiresAt,
            user: AuthUser(id: shared.userID, email: shared.email, fullName: nil)
        )
    }

    /// Saves the session as the shared sign-in, unless it's already there or another app
    /// has a newer one for the same user. Never an anonymous session.
    nonisolated private static func share(_ session: AuthSession) {
        guard !ScreenshotMode.isOn, session.user.isAnonymous != true else { return }
        if let current = HearthAccounts.session(), current.userID == session.user.id {
            if current.refreshToken == session.refreshToken && current.accessToken == session.accessToken { return }
            if current.expiresAt > session.expiresAt { return }
        }
        HearthAccounts.saveSession(HearthSharedSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt,
            userID: session.user.id,
            email: session.user.email,
            updatedBy: .bigtable
        ))
    }

    // MARK: Plumbing

    /// `share`: also save it as the Hearth apps' shared sign-in (after signing in or
    /// refreshing; not for a session that came from there).
    private func set(_ new: AuthSession?, share: Bool = true) {
        session = new
        // Screenshot mode (Debug) keeps its demo session out of the Keychain.
        if !ScreenshotMode.isOn {
            if let new { store.save(new) } else { store.delete() }
            if share, let new {
                Self.share(new)
                if HearthAccounts.session()?.userID == new.user.id { sharedUserID = new.user.id }
            }
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
        var is_anonymous: Bool?

        var user: AuthUser {
            AuthUser(id: id, email: email, fullName: user_metadata?["full_name"]?.string, isAnonymous: is_anonymous)
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
