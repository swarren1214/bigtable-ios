import Foundation
import SwiftUI

/// Manage Tags (from Profile, or from a recipe's Tags): the tags you made. Rename one and it's
/// renamed on every recipe that has it; delete one and recipes keep it, but it's no longer
/// offered.
struct ManageTagsView: View {
    @State private var isLoading = true
    @State private var renaming: CustomTag?
    @State private var renameText = ""
    @State private var isCreating = false
    @State private var newTagText = ""
    @State private var deleting: CustomTag?
    @State private var busyID: String?
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var confirmation: String?

    private var library: RecipeLibrary { .shared }

    var body: some View {
        List {
            if library.customTags.isEmpty {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading your tags…").foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No tags yet", systemImage: "tag")
                    } description: {
                        Text("Create a tag with + here, or from the Tags section when you write a recipe.")
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(library.customTags) { tag in
                        row(tag)
                    }
                } footer: {
                    Text("Renaming a tag renames it on every recipe that has it. Deleting a tag removes it from this list; recipes already tagged keep it.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Manage Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isAdding {
                    ProgressView()
                } else {
                    Button("New Tag", systemImage: "plus") {
                        newTagText = ""
                        isCreating = true
                    }
                }
            }
        }
        .refreshable { await library.loadCustomTags(force: true) }
        .task {
            await library.loadCustomTags(force: true)
            isLoading = false
        }
        .alert("New Tag", isPresented: $isCreating) {
            TextField("Tag name", text: $newTagText)
                .textInputAutocapitalization(.characters)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await create() } }
        } message: {
            Text("Up to 30 characters.")
        }
        .alert("Rename Tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { tag in
            TextField("Tag name", text: $renameText)
                .textInputAutocapitalization(.characters)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await rename(tag) } }
        } message: { tag in
            Text("“\(tag.label)” will be renamed everywhere it's used, including recipes already tagged with it.")
        }
        .alert(
            "Delete “\(deleting?.label ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { tag in
            Button("Delete Tag", role: .destructive) { Task { await delete(tag) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's removed from your saved tags. Recipes already tagged with it keep the tag.")
        }
        .alert("Done", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(confirmation ?? "")
        }
        .errorAlert($errorMessage, title: "Couldn't update the tag")
    }

    private func row(_ tag: CustomTag) -> some View {
        HStack {
            Label(tag.label, systemImage: "tag")
            Spacer()
            if busyID == tag.id {
                ProgressView()
            } else {
                Button {
                    renameText = tag.label
                    renaming = tag
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Rename \(tag.label)")
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = tag }
            Button("Rename", systemImage: "pencil") {
                renameText = tag.label
                renaming = tag
            }
            .tint(.orange)
        }
        .contextMenu {
            Button("Rename", menuIcon: "pencil") {
                renameText = tag.label
                renaming = tag
            }
            Button("Delete", menuIcon: "trash", role: .destructive) { deleting = tag }
        }
    }

    private static func clean(_ text: String) -> String {
        let collapsed = text.recipeTrimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(collapsed.prefix(30))
    }

    private func create() async {
        let label = Self.clean(newTagText)
        guard !label.isEmpty else { return }
        if let preset = RecipeQuickFilters.presetLabel(for: label.lowercased()) {
            errorMessage = "“\(preset)” is already a built-in tag."
            return
        }
        isAdding = true
        defer { isAdding = false }
        do {
            _ = try await library.createTag(label)
        } catch {
            errorMessage = library.tagErrorMessage(error, label: label)
        }
    }

    private func rename(_ tag: CustomTag) async {
        let label = Self.clean(renameText)
        guard !label.isEmpty else {
            errorMessage = "Enter a name for this tag."
            return
        }
        guard label.lowercased() != tag.label.lowercased() else { return }
        busyID = tag.id
        defer { busyID = nil }
        do {
            let renamed = try await library.renameTag(tag, to: label)
            confirmation = "“\(tag.label)” is now “\(renamed.label)”."
            RecipeLibrary.shared.changed()
        } catch {
            errorMessage = library.tagErrorMessage(error, label: label)
        }
    }

    private func delete(_ tag: CustomTag) async {
        busyID = tag.id
        defer { busyID = nil }
        do {
            try await library.deleteTag(tag)
        } catch {
            errorMessage = library.tagErrorMessage(error, label: tag.label)
        }
    }
}
