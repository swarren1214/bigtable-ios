import SwiftUI

/// Tell the Pantry from the wrist: say what you have ("2 gallons of milk and 3 dozen eggs") and
/// the iPhone puts it away, as Tell the Pantry does there, then shows what changed.
struct PantryView: View {
    @Environment(WatchStore.self) private var store

    private enum Phase: Equatable {
        case idle
        case sending(String)
        case done(String, [WatchPantryLine])
        case failed(String, String)
    }

    @State private var phase: Phase = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch phase {
                case .idle:
                    Text("Say what's in the fridge, freezer or pantry, or what you're out of.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“2 gallons of milk”")
                        Text("“We're out of butter”")
                        Text("“The flour bin is half full”")
                    }
                    .font(.footnote.weight(.medium))
                case .sending(let text):
                    Heard(text: text) {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                case .done(let text, let lines):
                    Heard(text: text) {
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
                    }
                case .failed(let text, let message):
                    Heard(text: text) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                TextFieldLink(prompt: Text("Say what you have")) {
                    Label(phase == .idle ? "Tell the Pantry" : "Say More", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                } onSubmit: { text in
                    send(text)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending)
            }
        }
        .navigationTitle("Pantry")
        .bigTablePage()
    }

    private var isSending: Bool {
        if case .sending = phase { return true }
        return false
    }

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        phase = .sending(text)
        Task {
            do {
                let lines = try await store.tellPantry(text)
                phase = .done(text, lines)
            } catch {
                phase = .failed(text, error.localizedDescription)
            }
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
