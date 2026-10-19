// HearthHouseholdViews.swift — the household screens every Hearth app shows: the household,
// a person, adding or editing someone, inviting, and first-time setup.
//
// Canonical copy: ~/Developer/hearthkit/HearthHouseholdViews.swift (run sync.sh after editing).
// Each app passes its own color (`accent`); everything else looks the same in every app. The
// sheet buttons come from each app's DesignSystem/SheetButtons.swift and menu icons from
// DesignSystem/MenuIcon.swift.

import CloudKit
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Avatar

struct HearthMemberAvatar: View {
    var member: HearthMember
    var size: CGFloat = 44
    var ring = true

    var body: some View {
        Group {
            if let name = member.photo, let data = Hearth.photo(named: name), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(member.initial)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(member.color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .padding(ring ? max(2, size * 0.04) : 0)
        .overlay {
            if ring { Circle().strokeBorder(member.color, lineWidth: max(2, size * 0.04)) }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The household

/// The household: everyone, grouped into parents and kids, with invitations, adding people and
/// the privacy note. Push it from Profile or Family; it shows first-time setup when there's
/// no household yet.
struct HearthHouseholdView: View {
    var accent: Color
    @State private var store = HearthHouseholdStore.shared
    @State private var adding = false
    @State private var inviting = false
    @State private var picksMe = false

    var body: some View {
        Group {
            if store.exists {
                list
            } else {
                HearthHouseholdSetupView(accent: accent)
            }
        }
        .navigationTitle("Household")
        .toolbar {
            if store.exists && store.canEditEveryone {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Person", systemImage: "plus") { adding = true }
                }
            }
        }
        .sheet(isPresented: $adding) {
            HearthPersonEditor(member: nil, accent: accent)
        }
        .sheet(isPresented: $inviting) {
            HearthInviteSheet(accent: accent)
        }
        .refreshable { await store.refresh() }
    }

    private var list: some View {
        List {
            Section {
                summary
            }
            if store.me == nil && !store.people.isEmpty {
                Section {
                    Button { picksMe = true } label: {
                        Label { Text("Which one is you?").foregroundStyle(.primary) } icon: { Image.menuIcon("person.crop.circle.badge.questionmark") }
                    }
                } footer: {
                    Text("So every Hearth app on this \(UIDevice.current.localizedModel) knows who's using it.")
                }
            }
            if !store.parents.isEmpty {
                Section("Parents and Adults") {
                    ForEach(store.parents) { row($0) }
                }
            }
            if !store.kids.isEmpty {
                Section("Kids") {
                    ForEach(store.kids) { row($0) }
                }
            }
            if !store.pendingParticipants.isEmpty {
                Section("Invited") {
                    ForEach(store.pendingParticipants, id: \.self) { participant in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.clock")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.name(of: participant))
                                Text("Invitation sent")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if store.canEditEveryone {
                Section {
                    Button { adding = true } label: {
                        Label { Text("Add a Person").foregroundStyle(.primary) } icon: { Image.menuIcon("person.badge.plus") }
                    }
                    if !store.isMember {
                        Button { inviting = true } label: {
                            Label { Text("Invite to Household").foregroundStyle(.primary) } icon: { Image.menuIcon("square.and.arrow.up") }
                        }
                    }
                }
            }
            if store.isMember {
                Section {
                    Button(role: .destructive) {
                        Task { await store.leave() }
                    } label: {
                        Text("Leave Household")
                    }
                } footer: {
                    Text(store.ownerName.map { "\($0) shares this household with you." } ?? "This household is shared with you.")
                }
            }
            Section {
                EmptyView()
            } footer: {
                Label("Your household is kept in your family's iCloud. Birthdays, allergies and diets are end-to-end encrypted, and Hearth's servers never see them.", systemImage: "lock")
                    .font(.footnote)
            }
            if let problem = store.problem {
                Section {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationDestination(for: String.self) { id in
            HearthPersonView(memberID: id, accent: accent)
        }
        .confirmationDialog("Which one is you?", isPresented: $picksMe, titleVisibility: .visible) {
            ForEach(store.people) { member in
                Button(member.trimmedName) { store.claim(member.id) }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.info?.name ?? "Household")
                        .font(.title3.bold())
                    Text(summaryLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: -10) {
                    ForEach(store.people.prefix(5)) { member in
                        HearthMemberAvatar(member: member, size: 30, ring: false)
                            .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2.5))
                    }
                }
            }
            Text("The same family in every Hearth app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var summaryLine: String {
        let count = store.people.count
        var line = "\(count) \(count == 1 ? "person" : "people")"
        if let organizer = store.organizer { line += " · \(organizer.firstName) is the organizer" }
        return line
    }

    private func row(_ member: HearthMember) -> some View {
        NavigationLink(value: member.id) {
            HStack(spacing: 12) {
                HearthMemberAvatar(member: member, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.trimmedName)
                        .font(.body.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(detail(member))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let allergy = member.allergies.first {
                            Text(member.allergies.count > 1 ? "\(allergy) +\(member.allergies.count - 1)" : allergy)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.red)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.12), in: .capsule)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func detail(_ member: HearthMember) -> String {
        var parts: [String] = []
        if member.id == store.info?.organizerID { parts.append("Organizer") } else if member.role != .kid { parts.append(member.role.label) }
        if let age = member.age() { parts.append("\(age)") }
        if member.id == store.me?.id { parts.append("You") }
        return parts.joined(separator: " · ")
    }

    /// An invited person's name, or how they were invited.
    static func name(of participant: CKShare.Participant) -> String {
        if let components = participant.userIdentity.nameComponents {
            let name = components.formatted(.name(style: .medium))
            if !name.isEmpty { return name }
        }
        let lookup = participant.userIdentity.lookupInfo
        return lookup?.emailAddress ?? lookup?.phoneNumber ?? "Someone"
    }
}

// MARK: - A person

struct HearthPersonView: View {
    var memberID: String
    var accent: Color
    @Environment(\.hearthPersonExtras) private var personExtras
    @State private var store = HearthHouseholdStore.shared
    @State private var editing = false
    @State private var confirmsArchive = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let member = store.member(memberID) {
                content(member)
            } else {
                ContentUnavailableView("No Longer in the Household", systemImage: "person.slash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ member: HearthMember) -> some View {
        List {
            Section {
                VStack(spacing: 8) {
                    HearthMemberAvatar(member: member, size: 96)
                    Text(member.trimmedName)
                        .font(.title2.bold())
                    Text(subtitle(member))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                chipsRow("Allergies", member.allergies, empty: "None", danger: true)
                chipsRow("Diet", member.diet, empty: "No restrictions")
                chipsRow("Likes", member.likes, empty: "Not set")
                chipsRow("Dislikes", member.dislikes, empty: "Not set")
            } header: {
                HStack {
                    Text("Food")
                    Spacer()
                    Label("Encrypted", systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
            }
            // What each app keeps about the person (Caloma's points, Suffice's allowance).
            if let extras = personExtras {
                extras(member)
            }
            Section("Account") {
                Text(accountLine(member))
                    .foregroundStyle(.secondary)
                if member.id != store.me?.id && store.me == nil {
                    Button("This Is Me") { store.claim(member.id) }
                }
            }
            if store.canEditEveryone && member.id != store.info?.organizerID {
                Section {
                    Button(member.isArchived ? "Restore \(member.firstName)" : "Archive \(member.firstName)", role: member.isArchived ? nil : .destructive) {
                        if member.isArchived { store.archive(member.id, archived: false) } else { confirmsArchive = true }
                    }
                } footer: {
                    Text("Archiving hides \(member.firstName) in every Hearth app and keeps their history.")
                }
            }
        }
        .toolbar {
            if store.canEdit(member) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
            }
        }
        .sheet(isPresented: $editing) {
            HearthPersonEditor(member: member, accent: accent)
        }
        .alert("Archive \(member.firstName)?", isPresented: $confirmsArchive) {
            Button("Archive", role: .destructive) {
                store.archive(member.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll be hidden in every Hearth app. Their history stays.")
        }
    }

    private func subtitle(_ member: HearthMember) -> String {
        var parts = [member.id == store.info?.organizerID ? "Organizer" : member.role.label]
        if let age = member.age() { parts.append("\(age)") }
        if let birthDate = member.birthDate { parts.append("birthday " + birthDate.formatted(.dateTime.month(.wide).day())) }
        return parts.joined(separator: " · ")
    }

    private func accountLine(_ member: HearthMember) -> String {
        if member.id == store.me?.id { return "You, on this \(UIDevice.current.localizedModel)" }
        if member.appleUserID != nil { return "Has joined with their own Apple Account" }
        return member.role == .kid ? "Managed by parents" : "Hasn't joined on their own device"
    }

    @ViewBuilder
    private func chipsRow(_ title: String, _ values: [String], empty: String, danger: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if values.isEmpty {
                Text(empty)
            } else {
                HearthChipFlow(values: values, tint: danger ? .red : accent)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Chips that wrap onto as many lines as they need.
struct HearthChipFlow: View {
    var values: [String]
    var tint: Color

    var body: some View {
        HearthFlowLayout(spacing: 6) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.12), in: .capsule)
            }
        }
    }
}

struct HearthFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let last = rows.count - 1
            rows[last].width = rows[last].indices.isEmpty ? size.width : rows[last].width + spacing + size.width
            rows[last].height = max(rows[last].height, size.height)
            rows[last].indices.append(index)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: - Adding or editing someone

struct HearthPersonEditor: View {
    var member: HearthMember?
    var accent: Color
    @State private var store = HearthHouseholdStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft = HearthMember(name: "", role: .kid, colorHex: 0x0A7AFF)
    @State private var hasBirthday = false
    @State private var birthday = Calendar.current.date(byAdding: .year, value: -8, to: .now) ?? .now
    @State private var color: HearthColorChoice = .palette("blue")
    @State private var pickingColor = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var removesPhoto = false
    @State private var loaded = false

    static let commonAllergens = ["Peanuts", "Tree nuts", "Dairy", "Eggs", "Gluten", "Shellfish", "Fish", "Soy", "Sesame"]
    static let commonDiets = ["Vegetarian", "Vegan", "Pescatarian", "Gluten-free", "Dairy-free", "Halal", "Kosher", "No pork", "Low sugar"]

    private var isNew: Bool { member == nil }
    private var canChangeRole: Bool { store.canEditEveryone && draft.id != store.info?.organizerID }
    private var isValid: Bool { !draft.trimmedName.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            avatarPreview
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose a photo")
                        if photoData != nil || (draft.photo != nil && !removesPhoto) {
                            Button("Remove Photo", role: .destructive) {
                                photoData = nil
                                removesPhoto = true
                            }
                            .font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.words)
                        .font(.title3)
                    Toggle("Birthday", isOn: $hasBirthday.animation())
                    if hasBirthday {
                        DatePicker("Born", selection: $birthday, in: ...Date.now, displayedComponents: .date)
                    }
                }

                Section {
                    Picker("Role", selection: $draft.role) {
                        ForEach(HearthRole.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!canChangeRole)
                } header: {
                    Text("Role")
                } footer: {
                    Text(draft.role.note)
                }

                Section {
                    Button { pickingColor = true } label: {
                        HearthColorLabel(initial: draft.trimmedName.isEmpty ? "?" : draft.trimmedName, color: color)
                    }
                    .hearthColorPicker(isPresented: $pickingColor, title: draft.trimmedName, caption: draft.role.label, color: $color)
                }

                Section {
                    HearthChoiceTokens(values: $draft.allergies, suggestions: Self.commonAllergens, tint: .red, addLabel: "Other Allergy")
                } header: {
                    HStack {
                        Text("Allergies")
                        Spacer()
                        Label("Encrypted", systemImage: "lock.fill").font(.caption)
                    }
                } footer: {
                    Text("Hard rules: BigTable and Sated's Coach never suggest food that contains them. Only your family can read them.")
                }

                Section("Diet") {
                    HearthChoiceTokens(values: $draft.diet, suggestions: Self.commonDiets, tint: accent, addLabel: "Other Diet")
                }

                Section("Likes") {
                    HearthChoiceTokens(values: $draft.likes, suggestions: [], tint: accent, addLabel: "Add a Like")
                }

                Section("Dislikes") {
                    HearthChoiceTokens(values: $draft.dislikes, suggestions: [], tint: .secondary, addLabel: "Add a Dislike")
                }
            }
            .navigationTitle(isNew ? "New Person" : "Edit \(member?.firstName ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton(isNew ? "Add" : "Save") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear(perform: load)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        photoData = data
                        removesPhoto = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        let preview: HearthMember = {
            var copy = draft
            copy.colorHex = color.hex
            return copy
        }()
        ZStack(alignment: .bottomTrailing) {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(.circle)
            } else if removesPhoto {
                HearthMemberAvatar(member: { var copy = preview; copy.photo = nil; return copy }(), size: 96)
            } else {
                HearthMemberAvatar(member: preview, size: 96)
            }
            Image(systemName: "camera.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(accent, in: .circle)
                .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 2))
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let member {
            draft = member
            color = HearthColorChoice(hex: member.colorHex)
            if let date = member.birthDate {
                hasBirthday = true
                birthday = date
            }
        } else {
            let used = Set(store.people.map(\.colorHex))
            let next = HearthPalette.colors.first { !used.contains($0.hex) } ?? HearthPalette.colors[5]
            color = .palette(next.id)
            draft.role = store.people.isEmpty ? .parent : .kid
        }
    }

    private func save() {
        var updated = draft
        updated.name = draft.trimmedName
        updated.colorHex = color.hex
        updated.birthday = hasBirthday ? HearthDay.string(from: birthday) : nil
        if let photoData {
            updated.photo = HearthHouseholdPhotos.save(photoData, memberID: updated.id) ?? updated.photo
        } else if removesPhoto {
            updated.photo = nil
        }
        store.save(updated)
        dismiss()
    }
}

/// Suggestions to tap on and off, plus anything typed in.
struct HearthChoiceTokens: View {
    @Binding var values: [String]
    var suggestions: [String]
    var tint: Color
    var addLabel: String
    @State private var adding = false
    @State private var text = ""

    private var choices: [String] {
        let extra = values.filter { value in !suggestions.contains { $0.caseInsensitiveCompare(value) == .orderedSame } }
        return suggestions + extra
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !choices.isEmpty {
                HearthFlowLayout(spacing: 8) {
                    ForEach(choices, id: \.self) { choice in
                        let isOn = values.contains { $0.caseInsensitiveCompare(choice) == .orderedSame }
                        Button {
                            if isOn {
                                values.removeAll { $0.caseInsensitiveCompare(choice) == .orderedSame }
                            } else {
                                values.append(choice)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isOn { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                                Text(choice)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOn ? tint : Color.primary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(isOn ? tint.opacity(0.14) : Color(.tertiarySystemFill), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            if adding {
                TextField(addLabel, text: $text)
                    .submitLabel(.done)
                    .onSubmit(add)
            } else {
                Button(addLabel) { adding = true }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func add() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, !values.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            values.append(value)
        }
        text = ""
        adding = false
    }
}

// MARK: - Inviting

struct HearthInviteSheet: View {
    var accent: Color
    @State private var store = HearthHouseholdStore.shared
    @State private var role: HearthRole = .adult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        HStack(spacing: -12) {
                            ForEach(store.people.prefix(3)) { member in
                                HearthMemberAvatar(member: member, size: 48, ring: false)
                                    .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 3))
                            }
                            Image(systemName: "plus")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(accent)
                                .frame(width: 48, height: 48)
                                .background(accent.opacity(0.14), in: .circle)
                                .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 3))
                        }
                        Text("Invite someone to \(store.info?.name ?? "your household")")
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                        Text("They'll see the household in every Hearth app they use, with the same names, photos and allergies.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(HearthRole.allCases) { option in
                        Button { role = option } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option == .kid ? "Kid with an iPhone" : option.label)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(option.note)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if role == option {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(accent)
                                }
                            }
                        }
                        .accessibilityAddTraits(role == option ? .isSelected : [])
                    }
                } header: {
                    Text("They'll join as")
                } footer: {
                    Text("Kids without their own Apple Account don't need an invitation. Add them as a person instead.")
                }
                if let problem = store.problem {
                    Section { Text(problem).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await store.presentInvite(as: role) }
                } label: {
                    HStack {
                        if store.isWorking { ProgressView().tint(.white) }
                        Text("Send Invitation")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(accent)
                .disabled(store.isWorking)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Invitations

/// An app's own sections on a person's page, after Food. Set once on the root view:
/// `.environment(\.hearthPersonExtras) { member in AnyView(PointsSection(member)) }`.
extension EnvironmentValues {
    @Entry var hearthPersonExtras: (@MainActor (HearthMember) -> AnyView)? = nil
}

/// The Household row every app shows (Settings or Profile): same name and symbol everywhere.
struct HearthHouseholdLabel: View {
    @State private var store = HearthHouseholdStore.shared

    var body: some View {
        LabeledContent {
            Text(store.exists ? "\(store.people.count)" : "")
        } label: {
            Label("Household", systemImage: HearthHouseholdLabel.symbol)
        }
    }

    static let symbol = "house.lodge"
    static let title = "Household"
}

extension View {
    /// Asks before joining a household someone shared. Put it on each app's root view.
    func hearthHouseholdInvitations() -> some View {
        modifier(HearthHouseholdInvitationAlert())
    }
}

private struct HearthHouseholdInvitationAlert: ViewModifier {
    @State private var store = HearthHouseholdStore.shared

    func body(content: Content) -> some View {
        content.alert(
            "Join \(store.inviterName)'s Household?",
            isPresented: Binding(get: { store.pendingInvite != nil }, set: { if !$0 { store.pendingInvite = nil } })
        ) {
            Button("Join") { Task { await store.acceptInvite() } }
            Button("Not Now", role: .cancel) { store.pendingInvite = nil }
        } message: {
            Text("Every Hearth app on this device will use their household: the same people, and the family's recipes, chores and budget. What you have now stays in your iCloud and comes back if you leave.")
        }
    }
}
