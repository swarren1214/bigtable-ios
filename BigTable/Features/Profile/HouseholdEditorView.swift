import Foundation
import SwiftUI

/// Profile › Household: the household's name and everyone in it. The organizer edits the name
/// and the people they manage; someone who joined edits only their own details. People who
/// joined with their own account open their permissions instead.
struct HouseholdEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = HouseholdDraft()
    @State private var saved = HouseholdDraft()
    @State private var hasLoaded = false
    @State private var editing: ProfileMemberDraft?
    @State private var isNewMember = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?
    @FocusState private var nameFocused: Bool

    private var isOrganizer: Bool { model.isOrganizer }
    private var nameChanged: Bool { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) != saved.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        BigTableScreen(title: "Household") {
            nameCard

            SectionTitle("People") {
                if isOrganizer && draft.members.count < HouseholdDraft.maxMembers {
                    Button("Add Person", systemImage: "plus") { addPerson() }
                        .disabled(isSaving)
                }
            }
            if draft.members.isEmpty {
                EmptyCard(symbol: "person.2", title: "No one yet", message: "Add the people you cook for.")
            } else {
                CardList(items: draft.members, inset: 74) { member in
                    memberRow(member)
                }
            }

            Text(isOrganizer
                 ? "Ages size the portions and restrictions shape the recipes BigTable suggests. People who join with their own account manage their own details."
                 : "You can change your own details. The organizer manages everyone else.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: 0x1E9E6A))
                    .padding(.horizontal, 4)
            }
        }
        .toolbar {
            if isOrganizer {
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", systemImage: "checkmark") {
                            nameFocused = false
                            Task { await save() }
                        }
                        .disabled(!nameChanged && draft == saved)
                    }
                }
            }
        }
        .sheet(item: $editing) { member in
            MemberEditorView(
                member: member,
                title: isNewMember ? "New Person" : member.displayName,
                color: color(for: member),
                canEdit: HouseholdDraft.canEdit(member, isOrganizer: isOrganizer, userID: model.userID),
                onSave: { updated in apply(updated) },
                onRemove: removable(member) ? { remove(member) } : nil
            )
        }
        .errorAlert($errorMessage, title: "Couldn't save the household")
        .onAppear(perform: loadIfNeeded)
        .onChange(of: model.me?.householdMembers) { _, _ in
            // Someone joined or left while this was open: start from the latest.
            if !isSaving && draft == saved { load() }
        }
    }

    // MARK: Pieces

    private var nameCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Household name")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isOrganizer {
                    HStack(spacing: 10) {
                        Image(systemName: "house.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("The Carter Family", text: $draft.name)
                            .font(.title3.weight(.semibold))
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .focused($nameFocused)
                            .onSubmit { Task { await save() } }
                    }
                } else {
                    Text(model.householdName.isEmpty ? "Household" : model.householdName)
                        .font(.title3.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: ProfileMemberDraft) -> some View {
        let role = roleLabel(member)
        let color = self.color(for: member)
        if isOrganizer, member.isJoined, let profileID = member.linkedProfileId {
            NavigationLink {
                ProfileJoinedMemberView(profileID: profileID, name: member.displayName, avatarURL: member.avatarURL, color: color)
            } label: {
                ProfileMemberRow(member: member, color: color, role: role)
            }
            .buttonStyle(.plain)
        } else if HouseholdDraft.canEdit(member, isOrganizer: isOrganizer, userID: model.userID) {
            Button {
                isNewMember = false
                editing = member
            } label: {
                ProfileMemberRow(member: member, color: color, role: role)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .accessibilityHint("Edits their details")
        } else {
            ProfileMemberRow(member: member, color: color, role: role, accessory: .lock)
        }
    }

    private func roleLabel(_ member: ProfileMemberDraft) -> String {
        draft.members.first?.id == member.id ? "Organizer" : member.ageLabel
    }

    private func color(for member: ProfileMemberDraft) -> Color {
        let position = draft.members.firstIndex { $0.id == member.id } ?? 0
        return PersonColor.forIndex(member.originalIndex ?? position).color
    }

    private func removable(_ member: ProfileMemberDraft) -> Bool {
        isOrganizer && !member.isJoined && draft.members.first?.id != member.id
            && draft.members.contains { $0.id == member.id }
    }

    // MARK: Changes

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        load()
    }

    private func load() {
        guard let me = model.me else { return }
        let fresh = HouseholdDraft(me: me, householdName: model.householdName, organizerProfileID: organizerProfileID)
        draft = fresh
        saved = fresh
    }

    private var organizerProfileID: String? {
        model.membership?.organizerProfileId ?? model.me?.profile?.id ?? model.userID
    }

    private func addPerson() {
        isNewMember = true
        editing = ProfileMemberDraft()
    }

    /// Done in the person sheet saves the household right away, as it did in the Expo app.
    private func apply(_ updated: ProfileMemberDraft) {
        if let index = draft.members.firstIndex(where: { $0.id == updated.id }) {
            draft.members[index] = updated
        } else if !updated.trimmedName.isEmpty {
            draft.members.append(updated)
        } else {
            return
        }
        Task { await save() }
    }

    private func remove(_ member: ProfileMemberDraft) {
        draft.members.removeAll { $0.id == member.id }
        Task { await save() }
    }

    private func save() async {
        guard !isSaving else { return }
        let payload: SaveHouseholdPayload
        do {
            payload = try draft.payload(
                isOrganizer: isOrganizer,
                userID: model.userID,
                organizerProfileID: organizerProfileID,
                householdName: isOrganizer ? nil : model.householdName
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isSaving = true
        savedMessage = nil
        defer { isSaving = false }
        do {
            try await model.saveHousehold(payload)
            // The save's reply leaves out the membership and joined people: read it all again.
            await model.reload()
            load()
            savedMessage = "Household saved"
        } catch {
            // Keep the edits on screen so Save can try again.
            errorMessage = error.localizedDescription
        }
    }
}
