import SwiftUI

/// The household step of every Hearth app's onboarding. Every app works inside a household
/// (a household of one is fine), so this sets one up, joins the family's, or, when another
/// Hearth app on this device already has one, just says so.
///
/// Put it in the app's onboarding with `onContinue` moving to the next step. It never lets the
/// person continue without a household: "Not Now" starts a household of just them, and says
/// where Household is in this app for when they're ready to add their family or join theirs.
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
    /// Stays up after the household exists, until the person taps Continue, so they see what
    /// happened (and, after Not Now, where to find Household later).
    @State private var presented = false

    private var needed: Bool { isActive && store.hasLoaded && !store.exists }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $presented) {
                HearthHouseholdOnboarding(accent: accent) { presented = false }
                    .interactiveDismissDisabled()
            }
            .onChange(of: needed, initial: true) { _, needed in
                if needed { presented = true }
            }
    }
}

struct HearthHouseholdOnboarding: View {
    var accent: Color
    var onContinue: () -> Void
    @State private var store = HearthHouseholdStore.shared
    @State private var showsSetup = false
    @State private var waitsForInvite = false
    /// They chose Not Now: a household of just them was started for them.
    @State private var setUpLater = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if store.exists {
                    if setUpLater { laterCard } else { joinedCard }
                } else if store.pendingInvite != nil {
                    // The invitation alert can't show over this screen, so it's here.
                    invitationCard
                } else if waitsForInvite {
                    inviteSteps
                } else {
                    explainer
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
            } else if store.pendingInvite == nil && !waitsForInvite {
                Button(action: startJustMe) {
                    Text("Not Now")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glass)
                .disabled(!store.hasLoaded || store.isWorking)
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
        VStack(spacing: 14) {
            HearthLogo(size: 76)
                .padding(.bottom, 2)
            Text("Your Household")
                .font(.largeTitle.bold())
            Text("\(store.app.displayName) is one of the Hearth apps for family life. Your household is who you share them with, set up once for all of them.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ForEach(HearthAppInfo.order, id: \.self) { app in
                    HearthAppIcon(app: app, size: app == store.app ? 38 : 30)
                        .opacity(app == store.app ? 1 : 0.85)
                }
            }
            .padding(.top, 2)
            .accessibilityHidden(true)
        }
    }

    /// Not Now: a household of just this person, so the app works, set up properly later.
    /// Their name comes from another Hearth app on this device when one knows it.
    private func startJustMe() {
        let mine = HearthHouseholdPlanner.sources().filter { HearthHouseholdPlanner.meSourceIDs().contains($0.id) }
        var me = mine.isEmpty
            ? HearthMember(name: "Me", role: .parent, colorHex: HearthPalette.colors[5].hex)
            : HearthHouseholdPlanner.member(from: mine, sortOrder: 0)
        me.role = .parent
        let first = mine.isEmpty ? "" : me.firstName
        setUpLater = true
        store.create(
            name: first.isEmpty ? "My Household" : "\(first)'s Household",
            members: [me],
            organizerID: me.id
        )
    }

    /// Where Household is in each app, for "when you're ready".
    static func householdLocation(in app: HearthApp) -> String {
        switch app {
        case .bigtable, .suffice: "tap your picture at the top of the screen, then Household"
        case .sated: "tap the person button at the top of Today, then Household"
        case .caloma: "tap Family at the top of Home, then Household"
        case .hearken: "tap the person button at the top of Today and look under Household"
        }
    }

    private var laterCard: some View {
        VStack(spacing: 16) {
            Image(systemName: HearthHouseholdLabel.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(accent, in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Set Up Later")
                    .font(.title3.bold())
                Text("For now your household is just you, so everything in \(store.app.displayName) works.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("When you’re ready")
                    .font(.headline)
                Text("To add your family or join their household, \(Self.householdLocation(in: store.app)).")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can do it from any Hearth app, and only once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.14), in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    /// What a household is for, before asking for one.
    private var explainer: some View {
        VStack(alignment: .leading, spacing: 16) {
            point(symbol: HearthHouseholdLabel.symbol, title: "In \(store.app.displayName)", detail: Self.purpose(in: store.app))
            point(symbol: "square.stack.3d.up", title: "The same people in every app", detail: "Add someone once and BigTable, Suffice, Sated, Caloma and Hearken all know them. Change them anywhere and it changes everywhere.")
            point(symbol: "envelope", title: "One invitation", detail: "Invite your family once. They join in every Hearth app they use.")
            point(symbol: "lock", title: "Private to your family", detail: "Birthdays, allergies and diets are encrypted in your family’s iCloud, not on Hearth’s servers.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    /// What the household does in this app, from the person's side.
    static func purpose(in app: HearthApp) -> String {
        switch app {
        case .bigtable: "Plan meals around everyone’s tastes and allergies, and share recipes, the plan and the grocery list."
        case .suffice: "Share the budget with your partner and see who made each purchase."
        case .sated: "The coach keeps your household’s allergies and diets, and your own likes, in mind."
        case .caloma: "Chores, rewards and the family calendar, for each person in it."
        case .hearken: "Your reading stays yours, and Caloma can show whose reading is whose on the family calendar."
        }
    }

    private func point(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
                .tint(.primary)
                .disabled(store.isWorking)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get Started")
                .font(.title3.bold())
                .padding(.top, 8)
            choice(symbol: "house.fill", title: "Set Up My Household", detail: "Just you is fine. Add family now or later.") {
                showsSetup = true
            }
            choice(symbol: "envelope.open.fill", title: "Join My Family’s Household", detail: "Someone already set one up in a Hearth app. Join theirs instead of starting another.") {
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
                .tint(.primary)
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
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}

/// The Hearth mark (Assets.xcassets/Hearth/hearth, light and dark), with a symbol if the asset
/// is missing.
struct HearthLogo: View {
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let image = UIImage(named: "Hearth/hearth") {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "flame.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Hearth")
    }
}
