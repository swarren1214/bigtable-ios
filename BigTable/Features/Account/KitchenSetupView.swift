import SwiftUI

/// The first run after signing in: the household (HearthKit's shared step, the same in every
/// Hearth app). It sets one up (a household of one is fine), joins the family's, or carries on
/// with the one another Hearth app on this device already has.
struct KitchenSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @State private var confirmSignOut = false

    var body: some View {
        HearthHouseholdOnboarding(accent: accent) {
            model.markSetUp()
        }
        .overlay(alignment: .topTrailing) {
            Button("Sign Out") { confirmSignOut = true }
                .font(.subheadline.weight(.semibold))
                .tint(.primary)
                .frame(minHeight: 44)
                .padding(.horizontal, 20)
        }
        .alert("Sign out of BigTable?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
    }
}
