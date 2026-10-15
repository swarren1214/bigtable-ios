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

/// A person in the household list: photo, name, what they are and their restrictions.
struct ProfileMemberRow: View {
    enum Accessory { case chevron, lock, none }

    var member: ProfileMemberDraft
    var color: Color
    var role: String
    var accessory: Accessory = .chevron
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 14) {
            MemberAvatar(name: member.displayName, color: color, url: member.avatarURL, size: 44, hearthName: member.trimmedName)
            VStack(alignment: .leading, spacing: 3) {
                Text(member.displayName)
                    .font(.headline)
                    .foregroundStyle(member.trimmedName.isEmpty ? Color.secondary : Color.primary)
                HStack(spacing: 6) {
                    Text("\(role) · \(member.restrictionSummary)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if member.isJoined {
                        TagLabel(text: "Joined", color: accent)
                    }
                }
            }
            Spacer(minLength: 8)
            switch accessory {
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            case .lock:
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Only they can edit this")
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A capsule that can be switched on, for dietary restrictions. Filled with the accent when on.
struct ProfileOptionChip: View {
    var title: String
    var isOn: Bool
    var isEnabled = true
    var action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A like or dislike with a button to take it off.
struct ProfileRemovableTag: View {
    var text: String
    var color: Color
    var canRemove: Bool
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.subheadline.weight(.medium))
            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .symbolRenderingMode(.hierarchical)
                        .frame(minWidth: 24, minHeight: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(text)")
            }
        }
        .foregroundStyle(color)
        .padding(.leading, 12)
        .padding(.trailing, canRemove ? 4 : 12)
        .frame(minHeight: 34)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// Likes or dislikes: the ones there are as tags, and a field to add another.
struct ProfileTagEditor: View {
    var placeholder: String
    @Binding var items: [String]
    var color: Color
    var canEdit: Bool
    var emptyText: String
    @State private var newItem = ""

    private var trimmedNew: String { newItem.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        ProfileRemovableTag(text: item, color: color, canRemove: canEdit) {
                            guard items.indices.contains(index) else { return }
                            items.remove(at: index)
                        }
                    }
                }
            }
            if canEdit && items.count < 20 {
                HStack(spacing: 8) {
                    TextField(placeholder, text: $newItem)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .onChange(of: newItem) { _, value in
                            if value.count > 50 { newItem = String(value.prefix(50)) }
                        }
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .frame(minWidth: 44, minHeight: 36)
                    }
                    .buttonStyle(.borderless)
                    .disabled(trimmedNew.isEmpty)
                    .accessibilityLabel("Add")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func add() {
        let value = trimmedNew
        guard !value.isEmpty, items.count < 20 else { return }
        if !items.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            items.append(value)
        }
        newItem = ""
    }
}

/// A full-width glass button for a card's secondary action (Restore Purchases, Leave
/// Household).
struct ProfileSecondaryButton: View {
    var title: String
    var systemImage: String
    var role: ButtonRole? = nil
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
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

/// The web pages the Expo app linked to from Profile.
enum ProfileLinks {
    static let privacy = URL(string: "https://bigtableapp.com/privacy/")!
    static let terms = URL(string: "https://bigtableapp.com/terms/")!
    static let support = URL(string: "https://bigtableapp.com/support/")!
    static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
    static let supportEmail = "bigtablemeals@gmail.com"

    static var feedbackMail: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [URLQueryItem(name: "subject", value: "BigTable Feedback")]
        return components.url
    }
}
