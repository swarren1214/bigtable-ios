import SwiftUI

/// Which item is being edited, and the section it's in.
struct GroceryItemEditTarget: Identifiable, Hashable {
    var item: GroceryItem
    var sectionName: String
    var id: String { item.id }
}

/// The organizer editing one item: its name, how much, the Bulk tag, and which section it's
/// in. Delete is here too.
struct GroceryItemEditor: View {
    var target: GroceryItemEditTarget
    var sectionChoices: [String]
    var onSave: (_ name: String, _ quantity: String, _ bulk: Bool, _ section: String) -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var quantity: String
    @State private var bulk: Bool
    @State private var section: String
    @State private var confirmDelete = false

    init(target: GroceryItemEditTarget, sectionChoices: [String], onSave: @escaping (_ name: String, _ quantity: String, _ bulk: Bool, _ section: String) -> Void, onDelete: @escaping () -> Void) {
        self.target = target
        self.sectionChoices = sectionChoices
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: target.item.name)
        _quantity = State(initialValue: target.item.quantity)
        _bulk = State(initialValue: target.item.bulk)
        let match = sectionChoices.first { $0.caseInsensitiveCompare(target.sectionName) == .orderedSame }
        _section = State(initialValue: match ?? target.sectionName)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var choices: [String] {
        sectionChoices.contains(section) ? sectionChoices : sectionChoices + [section]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item", text: $name)
                        .textInputAutocapitalization(.sentences)
                    TextField("Quantity (2 lb, 1 bag…)", text: $quantity)
                } footer: {
                    if let meals = GroceryFormat.meals(target.item.meals) {
                        Text(meals)
                    }
                }

                Section {
                    Picker("Section", selection: $section) {
                        ForEach(choices, id: \.self) { choice in
                            Label(choice, systemImage: GroceryAisleStyle.symbol(choice)).tag(choice)
                        }
                    }
                    .tint(.primary)
                    Toggle("Bulk size", isOn: $bulk)
                } footer: {
                    Text("Bulk marks warehouse-size packs.")
                }

                Section {
                    Button("Delete Item", systemImage: "trash", role: .destructive) {
                        confirmDelete = true
                    }
                }
            }
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Save") {
                        onSave(name, quantity, bulk, section)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .alert("Delete \(target.item.name)?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Naming a new section for the list.
struct GroceryNewSectionSheet: View {
    var onAdd: (String) -> Bool

    init(onAdd: @escaping (String) -> Bool) {
        self.onAdd = onAdd
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var exists = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Section name", text: $name)
                        .focused($focused)
                        .textInputAutocapitalization(.words)
                        .onSubmit(add)
                } footer: {
                    if exists {
                        Text("That section is already on the list.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Like “Costco run” or “Party supplies”.")
                    }
                }
            }
            .navigationTitle("New Section")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Add", action: add)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(240)])
    }

    private func add() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if onAdd(name) {
            dismiss()
        } else {
            exists = true
        }
    }
}
