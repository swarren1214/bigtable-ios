import SwiftUI

/// Tell the Pantry from the wrist: say what you have ("2 gallons of milk and 3 dozen eggs") and
/// the iPhone puts it away, as Tell the Pantry does there, then shows what changed. The request
/// lives in WatchStore, so its result shows even after the app was in the background.
struct PantryView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        let request = store.pantryRequest
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let request {
                    Heard(text: request.text) {
                        switch request.status {
                        case .sending, .working:
                            HStack(spacing: 8) {
                                ProgressView()
                                    .frame(width: 20, height: 20)
                                Text(request.status == .sending ? "Sending…" : "Putting it away…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        case .waiting:
                            Text("Sent to your iPhone. What changed shows here when it's done.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        case .done(let lines):
                            if lines.isEmpty {
                                Text("Nothing to change in that.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(lines) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(.green)
                                        .accessibilityHidden(true)
                                    Text(line.name)
                                        .font(.body.weight(.medium))
                                    Spacer(minLength: 4)
                                    Text(line.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        case .failed(let message):
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Say what's in the fridge, freezer or pantry, or what you're out of.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“2 gallons of milk”")
                        Text("“We're out of butter”")
                        Text("“The flour bin is half full”")
                    }
                    .font(.footnote.weight(.medium))
                }

                TextFieldLink(prompt: Text("Say what you have")) {
                    Label(request == nil ? "Tell the Pantry" : "Say More", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                } onSubmit: { text in
                    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    store.tellPantry(text)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)

                if request != nil, !isBusy {
                    Button("Done") { store.clearPantryRequest() }
                }
            }
        }
        .navigationTitle("Pantry")
        .bigTablePage()
    }

    private var isBusy: Bool {
        switch store.pantryRequest?.status {
        case .sending, .working: true
        default: false
        }
    }
}

/// What was heard, with what came of it below.
private struct Heard<Content: View>: View {
    let text: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heard")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("“\(text)”")
                .font(.body.weight(.medium))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 20, style: .continuous))
    }
}
