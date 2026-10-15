import Foundation
import SwiftUI

/// What the AI planned, day by day, before it's saved: new meals, what they replace, and
/// what's kept. Add to Plan saves exactly this plan; Try Again asks for a different one.
struct AIPlanPreviewView: View {
    var store: AIPlanStore
    var onApplied: () -> Void
    var onRegenerate: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.accent) private var accent

    private var rows: [AIPlanPreviewRow] { store.preview?.rows ?? [] }
    private var newCount: Int { rows.filter { $0.change == .new }.count }
    private var replaceCount: Int { rows.filter { $0.change == .replaces }.count }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary)
                        .font(.headline)
                    Text("Nothing changes until you add it to the plan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if rows.isEmpty {
                Section {
                    ContentUnavailableView("No meals planned", systemImage: "sparkles", description: Text("Try again, or choose more days and meals."))
                }
            }

            ForEach(store.preview?.dates ?? [], id: \.self) { iso in
                Section(PlanDates.dayTitle(iso: iso)) {
                    ForEach(rows.filter { $0.isoDate == iso }) { row in
                        AIPlanPreviewRowView(row: row)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Try Again", systemImage: "arrow.clockwise", action: onRegenerate)
                    .disabled(store.phase.isBusy)
                    .accessibilityLabel("Plan something different")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    if await store.apply(model: model, router: router) {
                        onApplied()
                    }
                }
            } label: {
                Group {
                    if store.phase == .applying {
                        ProgressView()
                    } else {
                        Label("Add to Plan", systemImage: "checkmark")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(rows.isEmpty || store.phase.isBusy)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if newCount > 0 { parts.append(newCount == 1 ? "1 new meal" : "\(newCount) new meals") }
        if replaceCount > 0 { parts.append(replaceCount == 1 ? "1 replaced" : "\(replaceCount) replaced") }
        if parts.isEmpty { return rows.isEmpty ? "Nothing to add" : "Your plan stays the same" }
        return parts.joined(separator: ", ")
    }
}

/// One planned meal in the preview.
struct AIPlanPreviewRowView: View {
    var row: AIPlanPreviewRow
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 12) {
            RecipePhoto(url: row.imageUrl, cornerRadius: 12, symbolSize: 18)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.slot.label.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(row.slot.color)
                Text(row.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(row.change == .keeps ? .secondary : .primary)
                    .lineLimit(2)
                if let previous = row.previousTitle {
                    Text("Replaces \(previous)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            badge
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badge: some View {
        switch row.change {
        case .new: TagLabel(text: "New", color: accent)
        case .replaces: TagLabel(text: "Changed", color: .orange)
        case .keeps: TagLabel(text: "Kept", color: .secondary)
        case .same: TagLabel(text: "Same", color: .secondary)
        }
    }
}
