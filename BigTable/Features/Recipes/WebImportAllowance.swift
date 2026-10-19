import Foundation
import Observation

/// Imports from the web: three a calendar month for free, as many as you like with BigTable Plus
/// or Hearth+. Counted on this device (UserDefaults), per calendar month; a successful import
/// counts, a failed one doesn't.
///
/// The server doesn't enforce this yet (links are mostly read on the device); it should, so the
/// count follows the account rather than the phone.
@MainActor
@Observable
final class WebImportAllowance {
    static let shared = WebImportAllowance()
    static let freePerMonth = 3

    private static let key = "bigtable.webImports"

    /// "2026-10".
    private var month: String
    private var count: Int

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.key)
        month = stored?["month"] as? String ?? ""
        count = stored?["count"] as? Int ?? 0
    }

    /// Imports this calendar month.
    var used: Int { month == Self.currentMonth() ? count : 0 }
    /// Free imports left this month.
    var remaining: Int { max(0, Self.freePerMonth - used) }

    func recordImport() {
        let now = Self.currentMonth()
        count = used + 1
        month = now
        let stored: [String: Any] = ["month": now, "count": count]
        UserDefaults.standard.set(stored, forKey: Self.key)
    }

    private static func currentMonth() -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: .now)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}
