import CloudKit
import Foundation
import os

/// What to tell someone when something fails: plain words about what went wrong and what to do
/// next, never a system or server error's own text (codes, domains, "The operation couldn't be
/// completed"). Log the raw error where it's caught; show `FriendlyError.message(error)`.
///
/// - BigTable's own errors (`APIError`, `AuthError`, `RecipeEditorError`, …) already speak
///   plainly, so their text is used as is. A server message is used only when it reads like a
///   sentence written for people.
/// - Being offline, timing out, iCloud being full or signed out, and a lost session each get
///   their own line.
/// - Anything else gets `fallback`: the action that failed ("Your grocery list couldn't be
///   saved. Try again."), or a general line when the alert's title already says what failed.
nonisolated enum FriendlyError {
    static let tryAgain = "Something went wrong. Try again."

    static func message(_ error: Error, fallback: String = tryAgain) -> String {
        if let api = error as? APIError {
            if api.kind == .rejected {
                guard let text = api.message, isReadable(text) else { return fallback }
                return text
            }
            return api.errorDescription ?? fallback
        }
        if let auth = error as? AuthError {
            if case .rejected(let text) = auth { return isReadable(text) ? text : fallback }
            return auth.errorDescription ?? fallback
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "You appear to be offline. Connect to the internet and try again."
            case .timedOut:
                return "This is taking longer than expected. Try again in a moment."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "BigTable can't reach its server right now. Try again in a moment."
            default:
                return fallback
            }
        }
        if let cloud = error as? CKError {
            switch cloud.code {
            case .networkUnavailable, .networkFailure:
                return "You appear to be offline. Your changes are saved here and go to iCloud when you're back online."
            case .quotaExceeded:
                return "Your iCloud storage is full. Free up space in Settings › your name › iCloud, then try again."
            case .notAuthenticated:
                return "Sign in to iCloud in Settings to keep your kitchen on all your devices."
            default:
                return fallback
            }
        }
        if error is DecodingError || error is EncodingError { return fallback }
        // BigTable's own errors (declared in this app) are written for people.
        if error is LocalizedError, String(reflecting: type(of: error)).hasPrefix("BigTable."),
           let text = (error as? LocalizedError)?.errorDescription, isReadable(text) {
            return text
        }
        return fallback
    }

    /// A sentence for people, not a code, a field path or a stack of JSON.
    static func isReadable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 300, trimmed.contains(" ") else { return false }
        let technical = ["{", "}", "[", "]", "Error Domain", "NSError", "status code", "undefined", "null", "Exception", "_", "://"]
        return !technical.contains { trimmed.contains($0) }
    }
}
