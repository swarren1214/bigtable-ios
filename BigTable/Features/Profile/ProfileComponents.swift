import Foundation
import SwiftUI
import UIKit

/// A white card of settings rows, with hairlines placed by the caller (`ProfileDivider`).
struct ProfileCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

/// The hairline between rows in a `ProfileCard`, starting after the icon.
struct ProfileDivider: View {
    var inset: CGFloat = 64

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

/// A settings row: tinted icon tile, title, optional detail, and a chevron when it opens
/// something.
struct ProfileRow: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String? = nil
    var showsChevron = true
    var isDestructive = false
    var trailingText: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: isDestructive ? Brand.allergy : color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(isDestructive ? Brand.allergy : Color.primary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let trailingText {
                Text(trailingText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 56)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A settings row with a switch.
struct ProfileToggleRow: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var isDisabled = false

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: color)
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(isDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 56)
    }
}

/// Push notification helpers the Profile screens share.
enum ProfilePush {
    /// Set when the person turns push off in Notifications, so the app doesn't register again
    /// on its own. (Should move to `SettingsKey`; see the porting report.)
    static let disabledKey = "push.disabled"

    /// Removes this account's push tokens on the server (turning push off, signing out,
    /// deleting the account), as the Expo app did. Best effort.
    static func disableServerTokens() async {
        let api = BigTableAPI.shared
        do {
            let response: PushTokensResponse = try await api.get("/v1/bigtable/push-tokens")
            for entry in response.tokens where !entry.token.isEmpty {
                try? await api.registerPushToken(entry.token, enabled: false)
            }
        } catch {
            // Not worth stopping anyone over.
        }
    }
}

