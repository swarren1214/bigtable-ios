import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// One person's details: photo, name, date of birth (for portion sizes), likes, dislikes and
/// dietary restrictions. A sheet; Done hands the edited person back, and the household is
/// saved by whoever opened it.
struct MemberEditorView: View {
    var title: String
    var color: Color
    var canEdit: Bool
    var onSave: (ProfileMemberDraft) -> Void
    var onRemove: (() -> Void)?

    @State private var member: ProfileMemberDraft
    @State private var photoItem: PhotosPickerItem?
    @State private var previewPhoto: Data?
    @State private var isUploading = false
    @State private var uploadError: String?
    @State private var showCamera = false
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss

    init(
        member: ProfileMemberDraft,
        title: String,
        color: Color,
        canEdit: Bool,
        onSave: @escaping (ProfileMemberDraft) -> Void,
        onRemove: (() -> Void)? = nil
    ) {
        self.title = title
        self.color = color
        self.canEdit = canEdit
        self.onSave = onSave
        self.onRemove = onRemove
        _member = State(initialValue: member)
    }

    private static let defaultBirthday = ISODay.date(from: "2010-01-01") ?? .now

    private var hasPhoto: Bool { previewPhoto != nil || member.avatar != nil }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                Section("Name") {
                    TextField("Name", text: $member.name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .disabled(!canEdit)
                }
                birthdaySection
                Section("Likes") {
                    ProfileTagEditor(
                        placeholder: "Add a like",
                        items: $member.likes,
                        color: Color(hex: 0x1E9E6A),
                        canEdit: canEdit,
                        emptyText: "No likes added yet."
                    )
                }
                Section("Dislikes") {
                    ProfileTagEditor(
                        placeholder: "Add a dislike",
                        items: $member.dislikes,
                        color: Brand.preference,
                        canEdit: canEdit,
                        emptyText: "No dislikes added yet."
                    )
                }
                Section {
                    FlowLayout(spacing: 8) {
                        ForEach(restrictionOptions, id: \.self) { option in
                            ProfileOptionChip(title: option, isOn: member.restrictions.contains(option), isEnabled: canEdit) {
                                toggle(option)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Dietary restrictions")
                } footer: {
                    Text("BigTable leaves these out when it suggests recipes and plans meals.")
                }
                if canEdit, onRemove != nil {
                    Section {
                        Button("Remove from Household", systemImage: "trash", role: .destructive) {
                            confirmRemove = true
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                if canEdit {
                    ToolbarItem(placement: .confirmationAction) {
                        SheetDoneButton {
                            var finished = member
                            finished.name = member.trimmedName
                            onSave(finished)
                            dismiss()
                        }
                        .disabled(member.trimmedName.isEmpty || isUploading)
                    }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await upload(item) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    guard let jpeg = PhotoTools.jpeg(from: image, maxSide: 512) else { return }
                    Task { await upload(jpeg: jpeg) }
                }
                .ignoresSafeArea()
            }
            .alert("Remove \(member.displayName)?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) {
                    onRemove?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They'll be taken out of the household and its meal plans.")
            }
        }
    }

    // MARK: Sections

    private var photoSection: some View {
        Section {
            VStack(spacing: 14) {
                ZStack {
                    MemberAvatar(name: member.displayName, color: color, url: member.avatarURL, photo: previewPhoto, size: 108)
                    if isUploading {
                        Circle().fill(.black.opacity(0.35))
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: 108, height: 108)
                .accessibilityLabel(hasPhoto ? "\(member.displayName)'s photo" : "No photo")

                if canEdit {
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label(hasPhoto ? "Change Photo" : "Add Photo", systemImage: "photo")
                        }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button("Take Photo", systemImage: "camera") { showCamera = true }
                                .labelStyle(.iconOnly)
                        }
                        if hasPhoto {
                            Button("Remove Photo", systemImage: "xmark", role: .destructive) {
                                member.avatar = nil
                                previewPhoto = nil
                                uploadError = nil
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isUploading)
                }
                if let uploadError {
                    Text(uploadError)
                        .font(.footnote)
                        .foregroundStyle(Brand.allergy)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.clear)
    }

    private var birthdaySection: some View {
        Section {
            Toggle("Date of birth", isOn: Binding(
                get: { member.dateOfBirth != nil },
                set: { on in member.dateOfBirth = on ? (member.dateOfBirth ?? Self.defaultBirthday) : nil }
            ))
            .disabled(!canEdit)
            if member.dateOfBirth != nil {
                DatePicker(
                    "Born",
                    selection: Binding(
                        get: { member.dateOfBirth ?? Self.defaultBirthday },
                        set: { member.dateOfBirth = $0 }
                    ),
                    in: ...Date.now,
                    displayedComponents: .date
                )
                .disabled(!canEdit)
            }
        } footer: {
            Text(member.dateOfBirth == nil
                 ? "Optional. Without a date of birth, BigTable sizes portions for an adult."
                 : "BigTable uses age to size portions.")
        }
    }

    private var restrictionOptions: [String] {
        let extras = member.restrictions.filter { !HouseholdDraft.dietaryOptions.contains($0) }
        return HouseholdDraft.dietaryOptions + extras
    }

    // MARK: Actions

    private func toggle(_ option: String) {
        if let index = member.restrictions.firstIndex(of: option) {
            member.restrictions.remove(at: index)
        } else {
            member.restrictions.append(option)
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let jpeg = await PhotoTools.load(item, maxSide: 512) else {
            uploadError = "That photo couldn't be opened. Try another one."
            return
        }
        await upload(jpeg: jpeg)
    }

    /// Uploads right away, as the Expo app did, so saving never waits on a photo.
    private func upload(jpeg: Data) async {
        uploadError = nil
        previewPhoto = jpeg
        isUploading = true
        defer { isUploading = false }
        do {
            let key = "member-" + member.id.prefix(8).lowercased()
            let url = try await StorageClient.shared.uploadMemberPhoto(jpeg, memberKey: key)
            member.avatar = ProfileAvatar.storedValue(forUploadedURL: url)
        } catch {
            previewPhoto = nil
            uploadError = "The photo didn't upload. \(error.localizedDescription)"
        }
    }
}
