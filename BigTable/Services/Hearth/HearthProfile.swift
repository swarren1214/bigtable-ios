// HearthProfile.swift — the one Profile screen every Hearth app shows, and the profile photo at
// the top right of every main screen that opens it.
//
// Canonical copy: ~/Developer/hearthkit/HearthProfile.swift. Don't edit the copies inside the
// apps; edit this one and run ~/Developer/hearthkit/sync.sh. Needs HearthShared.swift,
// HearthApps.swift, HearthTour.swift, HearthAccount.swift, HearthSync.swift, HearthHouseholdViews.swift and
// HearthPaywall.swift, plus each app's DesignSystem/SheetButtons.swift (`SheetDoneButton`).
// Design: the HearthKit Profile canvas.
//
// The screen, top to bottom
//   Profile (large white title over the app's color header)
//   Hearth account: signed in, a Liquid Glass card (photo, name, how they signed in) that opens
//     the Hearth Account page with the app's own account section; signed out, that section
//     itself (Sign in with Apple)
//   Membership: the billing banner when a renewal failed, and Get / Manage Hearth+
//   Household and iCloud Sync (iCloud Sync opens the shared sync card)
//   <the app's own settings sections>
//   Hearth Apps
//   Help & Feedback: Take the Tour, Send Feedback, Support, Rate <App>
//   Legal: Privacy Policy, Terms of Use
//   Your Data: the app's own rows (Export…), then Erase <App> Data with a native alert
//   The app's icon, name and version, and the app's own credits
//
// Using it
// - At the root (on the TabView), once:
//
//       RootTabView()
//           .hearthProfile { SatedProfileView() }
//
// - On every main screen, the photo at the top right, always last in the trailing group:
//
//       ToolbarItemGroup(placement: .topBarTrailing) {
//           ...the screen's own buttons...
//           HearthProfileButton()
//       }
//
// - The app's profile view fills in the screen:
//
//       HearthProfileView(
//           app: .sated,
//           profile: account.profile,                         // nil when signed out
//           sync: HearthProfileSync(summary: "Your food log and goals") {
//               SyncMonitor.shared.snapshot
//           } syncNow: {
//               await SyncMonitor.shared.syncNow()
//           },
//           erase: HearthProfileErase(app: .sated, message: "This deletes…") {
//               await SatedDataEraser.eraseAll(in: context)
//           }
//       ) {
//           AccountSection()                                  // the app's Section with HearthAccountSection
//       } settings: {
//           Section("Sated") { ... HearthProfileRow ... }     // the app's own sections
//       } data: {
//           ShareLink(...)                                    // rows above Erase, or nothing
//       } about: {
//           Text("Credits…")                                  // lines under the version, or nothing
//       }
//
// - Rows in the app's sections: `HearthProfileRow` for the label (an icon in the text color,
//   the title, an optional value), inside the app's NavigationLink or Button. Toggles and
//   Pickers are fine as they are; give them `.tint(.primary)` where a menu would turn the app's
//   color.

import StoreKit
import SwiftUI
import UIKit

// MARK: - Presenting

/// Whether the Profile sheet is up. `HearthProfileButton` opens it; `.hearthProfile { }` on the
/// root view shows it.
@MainActor @Observable
final class HearthProfilePresenter {
    static let shared = HearthProfilePresenter()
    var isPresented = false

    func show() { isPresented = true }
    func dismiss() { isPresented = false }

    private init() {}
}

extension View {
    /// Shows the app's Profile as a sheet whenever `HearthProfileButton` is tapped. Put it on the
    /// root view (the TabView), once.
    func hearthProfile<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        modifier(HearthProfileSheet(profile: content))
    }
}

private struct HearthProfileSheet<Profile: View>: ViewModifier {
    let profile: () -> Profile
    @State private var presenter = HearthProfilePresenter.shared

    func body(content: Content) -> some View {
        @Bindable var presenter = presenter
        content.sheet(isPresented: $presenter.isPresented) {
            NavigationStack {
                profile()
            }
        }
    }
}

// MARK: - The photo at the top right

/// The person's photo (or initial) at the top right of every main screen, the same in every
/// Hearth app. Opens Profile. It's the household's photo of "me" (one photo per person across
/// the apps), so a new photo shows up here in every app at once.
///
/// Drawn as a live view, not an image: the toolbar repaints images in one flat color, which
/// would turn a photo into a plain white circle.
struct HearthProfileButton: View {
    /// Over the color header (white glyph when there's no one yet), or on a plain bar.
    var overHeader: Bool
    /// What tapping does; by default it opens the Profile sheet.
    var action: (() -> Void)?

    @State private var household = HearthHouseholdStore.shared

    init(overHeader: Bool = true, action: (() -> Void)? = nil) {
        self.overHeader = overHeader
        self.action = action
    }

    var body: some View {
        Button {
            if let action { action() } else { HearthProfilePresenter.shared.show() }
        } label: {
            HearthProfileAvatar(member: household.me, size: 30, glyph: overHeader ? .white : .primary)
        }
        .accessibilityLabel("Profile")
        .accessibilityHint(household.me.map { "Signed in as \($0.trimmedName)" } ?? "")
    }
}

/// The photo the profile button draws: the household photo of "me", their initial in their
/// color, or the person glyph when there's no one yet.
struct HearthProfileAvatar: View {
    var member: HearthMember?
    var size: CGFloat = 30
    var glyph: Color = .white

    var body: some View {
        if let member {
            HearthMemberAvatar(member: member, size: size, ring: false)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: size * 0.9))
                .foregroundStyle(glyph)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - What the app passes in

/// The iCloud Sync row and the page it opens. Leave it nil where the app doesn't sync with
/// iCloud.
struct HearthProfileSync {
    /// What syncs, as the start of a sentence: "Your food log and goals".
    var summary: String
    var sharing: HearthSyncSharing?
    /// Reads the app's current snapshot (from its observable sync monitor, so the row and the
    /// page follow it live).
    var snapshot: @MainActor () -> HearthSyncSnapshot
    var syncNow: () async -> Void

    init(
        summary: String,
        sharing: HearthSyncSharing? = nil,
        snapshot: @escaping @MainActor () -> HearthSyncSnapshot,
        syncNow: @escaping () async -> Void
    ) {
        self.summary = summary
        self.sharing = sharing
        self.snapshot = snapshot
        self.syncNow = syncNow
    }
}

/// The destructive row at the bottom: Erase <App> Data, or Leave Household where that's what
/// erasing means (a member's copy of shared data). Always confirmed with a native alert.
struct HearthProfileErase {
    var title: String
    /// The alert's title.
    var question: String
    /// The alert's message: what goes, and what stays.
    var message: String
    /// The alert's destructive button.
    var confirm: String
    /// Under the row.
    var footer: String?
    var symbol: String
    var action: () async -> Void

    init(
        app: HearthApp,
        title: String? = nil,
        question: String? = nil,
        message: String,
        confirm: String = "Erase",
        footer: String? = nil,
        symbol: String = "trash",
        action: @escaping () async -> Void
    ) {
        self.title = title ?? "Erase \(app.displayName) Data"
        self.question = question ?? "Erase \(app.displayName) Data?"
        self.message = message
        self.confirm = confirm
        self.footer = footer
        self.symbol = symbol
        self.action = action
    }
}

// MARK: - A row

/// A row's label in the app's own Profile sections: the icon in the text color (never the app's
/// color), the title, and an optional value on the right. Put it in a NavigationLink or Button.
struct HearthProfileRow: View {
    var title: String
    var systemImage: String
    var value: String?

    init(_ title: String, systemImage: String, value: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
    }

    var body: some View {
        LabeledContent {
            if let value, !value.isEmpty {
                Text(value)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - The screen

struct HearthProfileView<Account: View, Settings: View, DataRows: View, About: View>: View {
    let app: HearthApp
    /// Who's signed in; nil shows the app's account section (Sign in with Apple) at the top.
    let profile: HearthAccountProfile?
    var sync: HearthProfileSync?
    /// Starts an app's own tour. Leave it nil for the shared tour (HearthTour.swift), which
    /// Take the Tour runs on its own once the app has set it up.
    var tour: (() -> Void)?
    var erase: HearthProfileErase?
    let account: Account
    let settings: Settings
    let data: DataRows
    let about: About

    init(
        app: HearthApp,
        profile: HearthAccountProfile?,
        sync: HearthProfileSync? = nil,
        tour: (() -> Void)? = nil,
        erase: HearthProfileErase? = nil,
        @ViewBuilder account: () -> Account,
        @ViewBuilder settings: () -> Settings,
        @ViewBuilder data: () -> DataRows,
        @ViewBuilder about: () -> About
    ) {
        self.app = app
        self.profile = profile
        self.sync = sync
        self.tour = tour
        self.erase = erase
        self.account = account()
        self.settings = settings()
        self.data = data()
        self.about = about()
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @State private var showsAccount = false
    @State private var confirmsErase = false
    @State private var isErasing = false

    private var info: HearthAppInfo { app.info }

    var body: some View {
        Form {
            Section {
                Text("Profile")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white.opacity(colorScheme == .light ? 0.88 : 1))
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            .listSectionSpacing(8)

            if let profile {
                Section {
                    accountCard(profile)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            } else {
                account
            }

            Section {
                HearthBillingBanner()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                HearthMembershipRow()
            }

            Section {
                NavigationLink {
                    HearthHouseholdView(accent: info.color)
                } label: {
                    HearthHouseholdLabel()
                }
                if let sync {
                    NavigationLink {
                        HearthProfileSyncPage(app: app, sync: sync)
                    } label: {
                        HearthProfileSyncLabel(sync: sync)
                    }
                }
            }
            .tint(.primary)

            settings

            Section {
                NavigationLink {
                    HearthAppsView(current: app)
                } label: {
                    HearthAppsRowLabel(current: app)
                }
            }

            Section("Help & Feedback") {
                if let tour {
                    Button {
                        tour()
                    } label: {
                        HearthProfileRow("Take the Tour", systemImage: "play.circle")
                    }
                } else if !HearthTour.shared.steps.isEmpty {
                    // The shared tour (HearthTour.swift): close Profile, then show the app around.
                    Button {
                        dismiss()
                        HearthTour.shared.start(skippingWelcome: true, after: .milliseconds(600))
                    } label: {
                        HearthProfileRow("Take the Tour", systemImage: "play.circle")
                    }
                }
                Link(destination: feedbackURL) {
                    HearthProfileRow("Send Feedback", systemImage: "envelope")
                }
                Link(destination: HearthProfileLinks.support) {
                    HearthProfileRow("Support", systemImage: "questionmark.circle")
                }
                Button {
                    rate()
                } label: {
                    HearthProfileRow("Rate \(app.displayName)", systemImage: "star")
                }
            }
            .tint(.primary)

            Section("Legal") {
                Link(destination: HearthProfileLinks.privacy) {
                    HearthProfileRow("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: HearthProfileLinks.terms) {
                    HearthProfileRow("Terms of Use", systemImage: "doc.text")
                }
            }
            .tint(.primary)

            dataSection

            Section {
                footer
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(alignment: .top) { HearthProfileHeader(color: info.color) }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // The title is drawn large in the content, as on every color-header screen.
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            ToolbarItem(placement: .confirmationAction) {
                SheetDoneButton { dismiss() }
            }
        }
        .navigationDestination(isPresented: $showsAccount) {
            HearthProfileAccountPage(app: app) { account }
        }
        .alert(erase?.question ?? "", isPresented: $confirmsErase) {
            if let erase {
                Button(erase.confirm, role: .destructive) {
                    isErasing = true
                    Task {
                        await erase.action()
                        isErasing = false
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(erase?.message ?? "")
        }
    }

    // MARK: The account card

    /// Signed in: a Liquid Glass card over the color header, laid out top to bottom. It opens the
    /// Hearth Account page (the app's account section: its apps, Sign Out, Delete Account).
    private func accountCard(_ profile: HearthAccountProfile) -> some View {
        Button {
            showsAccount = true
        } label: {
            VStack(spacing: 4) {
                HearthAccountAvatar(app: app, profile: profile, size: 76)
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 3))
                    .padding(.bottom, 8)
                Text(HearthAccountIdentity.name(profile) ?? "Your Hearth Account")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(profile.method)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HearthMemberBadge()
                    .padding(.top, 4)
                HStack(spacing: 6) {
                    Text("Hearth Account")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .padding(.bottom, 16)
            .padding(.horizontal, 16)
            .contentShape(.rect(cornerRadius: 28))
            .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hearth Account, \(HearthAccountIdentity.name(profile) ?? ""), \(profile.method)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Your Data

    @ViewBuilder
    private var dataSection: some View {
        if let erase {
            Section {
                data
                    .tint(.primary)
                Button(role: .destructive) {
                    confirmsErase = true
                } label: {
                    HStack {
                        Label(erase.title, systemImage: erase.symbol)
                        if isErasing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .tint(.red)
                .disabled(isErasing)
            } footer: {
                if let footer = erase.footer {
                    Text(footer)
                }
            }
        } else if DataRows.self != EmptyView.self {
            Section {
                data
                    .tint(.primary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            HearthAppIcon(app: app, size: 60)
                .clipShape(.rect(cornerRadius: 60 * 0.225, style: .continuous))
            Text(app.displayName)
                .font(.headline)
                .padding(.top, 4)
            Text("Version \(HearthProfileLinks.version)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("A Hearth app · Hearth Software LLC")
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                about
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private var feedbackURL: URL {
        let subject = "\(app.displayName) \(HearthProfileLinks.version) Feedback"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(HearthProfileLinks.supportEmail)?subject=\(encoded)") ?? HearthProfileLinks.support
    }

    /// On the App Store, the review page; in a TestFlight beta, the system rating prompt (which
    /// TestFlight doesn't show, so nothing happens there).
    private func rate() {
        if case .appStore(let url) = info.availability,
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "action", value: "write-review")]
            if let review = parts.url {
                openURL(review)
                return
            }
        }
        requestReview()
    }
}

// MARK: - Pushed pages

/// Profile › Hearth Account: the app's own account section (its apps, account rows, Sign Out and
/// Delete Account). Signing out here brings back Sign in with Apple in place.
private struct HearthProfileAccountPage<Account: View>: View {
    let app: HearthApp
    let account: Account

    init(app: HearthApp, @ViewBuilder account: () -> Account) {
        self.app = app
        self.account = account()
    }

    var body: some View {
        Form {
            account
        }
        .navigationTitle("Hearth Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Profile › iCloud Sync: the shared sync card, live.
private struct HearthProfileSyncPage: View {
    let app: HearthApp
    let sync: HearthProfileSync

    var body: some View {
        Form {
            Section {
                HearthSyncCard(app: app, snapshot: sync.snapshot(), summary: sync.summary, sharing: sync.sharing) {
                    await sync.syncNow()
                }
                .hearthSyncCardRow()
            } footer: {
                Text("\(app.displayName) syncs on its own. Pull down on any screen to check for changes. Hearth’s servers never hold this data.")
            }
        }
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The iCloud Sync row: a status dot and a word.
private struct HearthProfileSyncLabel: View {
    let sync: HearthProfileSync

    private var network: HearthNetworkStatus { .shared }

    var body: some View {
        let snapshot = sync.snapshot()
        let status = Self.status(snapshot, online: network.isOnline)
        LabeledContent {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(status.text)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label {
                Text("iCloud Sync").foregroundStyle(.primary)
            } icon: {
                Image(systemName: "icloud").foregroundStyle(.primary)
            }
        }
    }

    private static func status(_ snapshot: HearthSyncSnapshot, online: Bool) -> (text: String, color: Color) {
        switch snapshot.account {
        case .checking: return ("Checking", .gray)
        case .unavailable: return ("Off", .gray)
        case .available: break
        }
        if snapshot.isSyncing { return ("Syncing", .blue) }
        if snapshot.errorMessage != nil { return ("Couldn’t Sync", .red) }
        if !online || (snapshot.pendingChanges ?? 0) > 0 { return ("Waiting", .orange) }
        return ("Up to Date", .green)
    }
}

// MARK: - Header

/// The app's color across the top, fading into the gray, as on every main screen.
private struct HearthProfileHeader: View {
    let color: Color

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let curve: [(Double, Double)] = sizeClass == .compact
            ? [(0, 1), (0.3, 0.88), (0.6, 0.5), (0.85, 0.15), (1, 0)]
            : [(0, 1), (1, 0)]
        let end = color.mix(with: .white, by: 0.12)
        GeometryReader { geo in
            LinearGradient(
                stops: curve.map { Gradient.Stop(color: color.mix(with: end, by: $0.0).opacity($0.1), location: $0.0) },
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: geo.size.width, height: geo.size.height * (sizeClass == .compact ? 0.5 : 0.4))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Links

enum HearthProfileLinks {
    static let support = URL(string: "https://hearthapps.com/support")!
    static let privacy = URL(string: "https://hearthapps.com/privacy")!
    static let terms = URL(string: "https://hearthapps.com/terms")!
    static let supportEmail = "support@hearthapps.com"

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
