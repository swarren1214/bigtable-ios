import Foundation
import SwiftUI

/// Profile › Privacy: whether this household shows up in Community, and the people it has
/// blocked.
struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    @State private var isVisible: Bool?
    @State private var isSavingVisibility = false
    @State private var confirmHideCount: Int?
    @State private var statusMessage: String?
    @State private var blocked: [ProfileBlockedPerson] = []
    @State private var blockedLoaded = false
    @State private var blockedError: String?
    @State private var unblocking: ProfileBlockedPerson?
    @State private var errorMessage: String?

    private var api: BigTableAPI { model.api }

    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: { isVisible ?? (model.me?.profile?.socialProfileVisible != false) },
            set: { on in Task { await setVisible(on) } }
        )
    }

    var body: some View {
        BigTableScreen(title: "Privacy") {
            ProfileCard {
                ProfileToggleRow(
                    symbol: "person.2",
                    color: PersonColor.teal.color,
                    title: "Show my profile in Community",
                    detail: "Lets other households find you, follow you and see your published recipes. The other people in your household are never public.",
                    isOn: visibilityBinding,
                    isDisabled: isSavingVisibility
                )
                if let userID = model.userID {
                    ProfileDivider()
                    NavigationLink {
                        PublicProfileView(profileID: userID)
                    } label: {
                        ProfileRow(symbol: "person.crop.circle.badge.checkmark", color: PersonColor.blue.color, title: "View My Community Profile")
                    }
                    .buttonStyle(.plain)
                }
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            SectionTitle("Blocked")
            if !blockedLoaded {
                if let blockedError {
                    RetryCard(message: blockedError) { Task { await loadBlocked() } }
                } else {
                    LoadingCard()
                }
            } else if blocked.isEmpty {
                EmptyCard(symbol: "hand.raised", title: "No one blocked", message: "People you block in Community can't see your profile or follow you.")
            } else {
                CardList(items: blocked, inset: 74) { person in
                    HStack(spacing: 14) {
                        MemberAvatar(name: person.name, color: PersonColor.forKey(person.id).color, url: person.avatarURL, size: 44)
                        Text(person.name).font(.headline)
                        Spacer(minLength: 8)
                        Button("Unblock") { unblocking = person }
                            .buttonStyle(.bordered)
                            .tint(.primary)
                            .accessibilityLabel("Unblock \(person.name)")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .task {
            await loadVisibility()
            await loadBlocked()
        }
        .refreshable {
            await loadVisibility()
            await loadBlocked()
        }
        .alert("Hide profile and unpublish recipes?", isPresented: Binding(get: { confirmHideCount != nil }, set: { if !$0 { confirmHideCount = nil } }), presenting: confirmHideCount) { _ in
            Button("Hide and Unpublish", role: .destructive) { Task { await applyVisible(false) } }
            Button("Cancel", role: .cancel) {}
        } message: { count in
            Text("You have \(count) published \(count == 1 ? "recipe" : "recipes"). Hiding your profile unpublishes \(count == 1 ? "it" : "all of them").")
        }
        .alert("Unblock \(unblocking?.name ?? "")?", isPresented: Binding(get: { unblocking != nil }, set: { if !$0 { unblocking = nil } }), presenting: unblocking) { person in
            Button("Unblock") { Task { await unblock(person) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They'll be able to see your profile and follow you again.")
        }
        .errorAlert($errorMessage)
    }

    // MARK: Visibility

    private func loadVisibility() async {
        if let response = try? await api.socialVisibility() {
            isVisible = response.socialProfileVisible
        }
    }

    private func setVisible(_ visible: Bool) async {
        if !visible {
            // Hiding unpublishes every published recipe: say so first, as the Expo app did.
            let published = (try? await api.socialVisibility())?.publishedRecipeCount ?? 0
            if published > 0 {
                confirmHideCount = published
                return
            }
        }
        await applyVisible(visible)
    }

    private func applyVisible(_ visible: Bool) async {
        let previous = isVisible
        isVisible = visible
        isSavingVisibility = true
        defer { isSavingVisibility = false }
        do {
            let response = try await api.setSocialVisibility(visible)
            isVisible = response.socialProfileVisible
            if visible {
                statusMessage = "Your profile shows in Community."
            } else if let count = response.unpublishedRecipeCount, count > 0 {
                statusMessage = "Your profile is hidden. \(count) published \(count == 1 ? "recipe was" : "recipes were") unpublished."
            } else {
                statusMessage = "Your profile is hidden from Community."
            }
        } catch {
            isVisible = previous
            errorMessage = FriendlyError.message(error)
            await loadVisibility()
        }
    }

    // MARK: Blocked

    private func loadBlocked() async {
        blockedError = nil
        do {
            let ids = try await api.blockedProfiles()
            var people: [ProfileBlockedPerson] = []
            for id in ids {
                let profile = try? await api.publicProfile(id)
                let name = (profile?.profile.profileName ?? "").trimmingCharacters(in: .whitespaces)
                people.append(ProfileBlockedPerson(
                    id: id,
                    name: name.isEmpty ? "A BigTable household" : name,
                    avatarURL: ProfileAvatar.url(for: profile?.profile.avatarUrl)
                ))
            }
            blocked = people
            blockedLoaded = true
        } catch {
            blockedError = FriendlyError.message(error)
        }
    }

    private func unblock(_ person: ProfileBlockedPerson) async {
        do {
            try await api.unblock(person.id)
            blocked.removeAll { $0.id == person.id }
            statusMessage = "\(person.name) is unblocked."
        } catch {
            errorMessage = FriendlyError.message(error)
        }
    }
}

/// Someone this household blocked.
nonisolated struct ProfileBlockedPerson: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var avatarURL: String?
}
