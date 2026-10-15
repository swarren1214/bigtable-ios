import Foundation
import SwiftUI

/// How strong a new password is, scored as the Expo app scored it: 0 very weak, 1 weak,
/// 2 moderate, 3 strong. Creating an account needs at least moderate.
nonisolated enum AccountPasswordStrength {
    static let minimumToSubmit = 2

    static func score(_ password: String) -> Int {
        guard !password.isEmpty else { return 0 }
        var points = 0
        if password.count >= 8 { points += 1 }
        if password.count >= 12 { points += 1 }
        if hasUppercase(password) { points += 1 }
        if hasNumber(password) { points += 1 }
        if hasSymbol(password) { points += 1 }
        switch points {
        case ...1: return 0
        case 2: return 1
        case 3: return 2
        default: return 3
        }
    }

    static func hasUppercase(_ password: String) -> Bool { password.contains { $0.isASCII && $0.isUppercase } }
    static func hasNumber(_ password: String) -> Bool { password.contains { $0.isASCII && $0.isNumber } }
    static func hasSymbol(_ password: String) -> Bool { password.contains { !($0.isASCII && ($0.isLetter || $0.isNumber)) } }
}

/// The meter under a new password: a bar, how strong it is, and what's still missing.
struct AccountPasswordGauge: View {
    var password: String

    private static let levels: [(label: String, color: Color)] = [
        ("Very weak", Color(hex: 0xDC2626)),
        ("Weak", Color(hex: 0xEA580C)),
        ("Moderate", Color(hex: 0xCA8A04)),
        ("Strong", Color(hex: 0x16A34A)),
    ]

    private var strength: Int { AccountPasswordStrength.score(password) }

    private var requirements: [(label: String, met: Bool)] {
        [
            ("At least 8 characters", password.count >= 8),
            ("An uppercase letter (A–Z)", AccountPasswordStrength.hasUppercase(password)),
            ("A number (0–9)", AccountPasswordStrength.hasNumber(password)),
            ("A symbol", AccountPasswordStrength.hasSymbol(password)),
        ]
    }

    var body: some View {
        let level = Self.levels[strength]
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(strength + 1), total: 4)
                .tint(level.color)
                .animation(.smooth, value: strength)
            Text(level.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(level.color)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(requirements.indices, id: \.self) { index in
                    let requirement = requirements[index]
                    Label {
                        Text(requirement.label)
                    } icon: {
                        Image(systemName: requirement.met ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(requirement.met ? Self.levels[3].color : Color.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(requirement.met ? Color.primary : Color.secondary)
                    .accessibilityLabel("\(requirement.label), \(requirement.met ? "done" : "missing")")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Password strength: \(level.label)")
    }
}
