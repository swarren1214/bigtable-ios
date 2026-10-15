import Foundation
import SwiftUI
import UIKit

/// "Add your family from Caloma?": offered to the organizer while setting up or editing the
/// household, when Caloma on this device knows people who aren't in the household yet.
struct CalomaFamilyCard: View {
    var names: [String]
    /// The card's color: grouped on Profile screens, plain gray on the onboarding pages.
    var background = Color(.secondarySystemGroupedBackground)
    var onAdd: () -> Void
    var onDismiss: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "person.2.fill", color: accent, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add your family from Caloma?")
                        .font(.headline)
                    Text(names.formatted(.list(type: .and)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not Now")
            }
            ProfileSecondaryButton(title: names.count == 1 ? "Add \(names[0])" : "Add All \(names.count)", systemImage: "plus", action: onAdd)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: .rect(cornerRadius: 22))
    }
}

/// Caloma's family, as offered on the household screens: read from the Hearth app group,
/// without the people the offer was dismissed for.
enum CalomaFamilyOffer {
    /// Caloma's family, or nil when there's none (or in screenshots).
    static func load() -> HearthFamily? {
        guard !ScreenshotMode.isOn,
              var family = Hearth.read(HearthFamily.self, from: .caloma)?.value else { return nil }
        let dismissed = dismissedNames
        family.members.removeAll { member in
            dismissed.contains { HouseholdDraft.sameName($0, member.name) }
        }
        return family.members.isEmpty ? nil : family
    }

    /// Not now: don't offer these people again.
    static func dismiss(_ names: [String]) {
        let all = dismissedNames + names.filter { !dismissedNames.contains($0) }
        UserDefaults.standard.set(all.joined(separator: "\n"), forKey: SettingsKey.calomaFamilyDismissed)
    }

    private static var dismissedNames: [String] {
        (UserDefaults.standard.string(forKey: SettingsKey.calomaFamilyDismissed) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }
}
