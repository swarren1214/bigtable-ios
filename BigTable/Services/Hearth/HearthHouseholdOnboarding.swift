import SwiftUI

/// The household step of every Hearth app's onboarding. Every app works inside a household
/// (a household of one is fine), so this sets one up, joins the family's, or, when another
/// Hearth app on this device already has one, just says so.
///
/// Put it in the app's onboarding with `onContinue` moving to the next step. It never lets the
/// person continue without a household.
extension View {
    /// Every Hearth app works inside a household: once the app's own onboarding is done
    /// (`isActive`), anyone without one gets the household step over everything until they
    /// have one.
    func hearthHouseholdRequired(isActive: Bool, accent: Color) -> some View {
        modifier(HearthHouseholdRequirement(isActive: isActive, accent: accent))
    }
}

private struct HearthHouseholdRequirement: ViewModifier {
    var isActive: Bool
    var accent: Color
    @State private var store = HearthHouseholdStore.shared

    private var needed: Bool { isActive && store.hasLoaded && !store.exists }

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { needed }, set: { _ in })) {
            HearthHouseholdOnboarding(accent: accent) {}
                .interactiveDismissDisabled()
        }
    }
}

struct HearthHouseholdOnboarding: View {
    var accent: Color
    var onContinue: () -> Void
    @State private var store = HearthHouseholdStore.shared
    @State private var showsSetup = false
    @State private var waitsForInvite = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if store.exists {
                    joinedCard
                } else if store.pendingInvite != nil {
                    // The invitation alert can't show over this screen, so it's here.
                    invitationCard
                } else if waitsForInvite {
                    inviteSteps
                } else {
                    choices
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if store.exists {
                Button(action: onContinue) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(accent)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 520)
            }
        }
        .sheet(isPresented: $showsSetup) {
            NavigationStack {
                HearthHouseholdSetupView(accent: accent)
                    .navigationTitle("Your Household")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            SheetCancelButton { showsSetup = false }
                        }
                    }
            }
            .tint(accent)
        }
        .onChange(of: store.exists) { _, exists in
            if exists { showsSetup = false }
        }
        .animation(.smooth, value: store.exists)
        .animation(.smooth, value: waitsForInvite)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: HearthHouseholdLabel.symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text("Your Household")
                .font(.largeTitle.bold())
            Text("The people you share home life with, the same in every Hearth app. Birthdays, allergies and diets stay encrypted in your family's iCloud.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var joinedCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: -10) {
                ForEach(store.people.prefix(6)) { person in
                    HearthMemberAvatar(member: person, size: 44, ring: true)
                }
            }
            Text(store.info?.name ?? "Your household")
                .font(.title3.bold())
            Text(store.people.count == 1 ? "Just you for now. Add people or invite your family any time in Household." : "\(store.people.count) people. Change anyone any time in Household.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    private var invitationCard: some View {
        VStack(spacing: 14) {
            Text("Join \(store.inviterName)'s Household?")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("Every Hearth app on this device will use their household: the same people, and the family's recipes, chores and budget.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await store.acceptInvite() }
            } label: {
                Group {
                    if store.isWorking { ProgressView() } else { Text("Join") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(accent)
            .disabled(store.isWorking)
            Button("Not Now") { store.pendingInvite = nil }
                .disabled(store.isWorking)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    private var choices: some View {
        VStack(spacing: 12) {
            choice(symbol: "house.fill", title: "Set Up My Household", detail: "Start with yourself; add your family now or later. People other Hearth apps already know are suggested.") {
                showsSetup = true
            }
            choice(symbol: "envelope.open.fill", title: "I've Been Invited", detail: "Someone in your family already uses a Hearth app and is inviting you.") {
                waitsForInvite = true
            }
        }
    }

    private var inviteSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step("1", "They open Household in any Hearth app and tap Invite to Household.")
            step("2", "They send it to you in Messages or Mail.")
            step("3", "You open it on this device. This screen moves on by itself.")
            HStack {
                ProgressView()
                Text(store.isWorking ? "Joining…" : "Waiting for the invitation…")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Button("Back") { waitsForInvite = false }
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    private func choice(symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(accent, in: .rect(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number)
                .font(.headline)
                .foregroundStyle(accent)
            Text(text)
        }
    }
}
