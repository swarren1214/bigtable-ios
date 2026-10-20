// HearthHouseholdStore.swift — keeps the household (`HearthHousehold.swift`) in iCloud and in
// step across the Hearth apps on this device.
//
// Canonical copy: ~/Developer/hearthkit/HearthHouseholdStore.swift (run sync.sh after editing).
//
// - The organizer's household is the zone "Household" in their private database of
//   iCloud.com.stephenwarren.hearth, shared with the family (a zone-wide CKShare). Everyone else
//   syncs it from their shared database. One record per person ("member-<id>") and one for the
//   household ("household"). Birthdays, allergies, diets, likes, dislikes and household rules
//   are encrypted (`encryptedValues`).
// - Every Hearth app runs its own copy of this store with its own CKSyncEngine, and writes what
//   it knows to the app group (`<app>.household.json`). Copies merge person by person, newest
//   change first, so an edit in one app shows in the others at once and every app uploads only
//   its own edits.
// - Without iCloud (signed out), the household still works on this device through the app group.
// - Joining someone's household (an invitation tapped in any Hearth app) switches every app on
//   the device: the others see the shared zone appear and follow.
//
// Each app calls `start(app:)` at launch, passes iCloud invitations for this container to
// `receive(_:)` from its scene delegate, and shows `.hearthHouseholdInvitations()` at its root.

import CloudKit
import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit

@MainActor
@Observable
final class HearthHouseholdStore: NSObject, CKSyncEngineDelegate {
    static let shared = HearthHouseholdStore()
    nonisolated static let containerID = "iCloud.com.stephenwarren.hearth"
    nonisolated static let zoneName = "Household"
    private static let householdRecordName = "household"
    private static let memberPrefix = "member-"

    enum Mode: Equatable {
        /// This account's own household (or none yet), in its private database.
        case owner
        /// Someone else's household this account joined; `ownerName` is their user record.
        case member(ownerName: String)
    }

    enum Account: Equatable {
        case checking, available, noAccount, unavailable
    }

    /// The household as this device knows it: every app's copy merged with iCloud.
    private(set) var snapshot: HearthHouseholdSnapshot = .empty
    private(set) var mode: Mode
    private(set) var account: Account = .checking
    /// The household's share: the organizer's once they've invited someone, or the one a
    /// member joined.
    private(set) var share: CKShare?
    /// This person's iCloud user record name, once known.
    private(set) var myUserID: String?
    /// The person picked as "me" on this device (shared by every Hearth app here). Used
    /// without iCloud, and until the iCloud account is known.
    private(set) var localMeID: String?
    private(set) var isWorking = false
    private(set) var isSyncing = false
    /// iCloud has been asked at least once (or isn't available), so `exists` can be trusted:
    /// a new device doesn't think there's no household before the family's arrives. Per
    /// database: joining or leaving waits for the new one.
    var hasLoaded: Bool {
        account == .unavailable || account == .noAccount || snapshot.exists
            || (isMember ? sharedFetched : privateFetched)
    }
    private var privateFetched = false
    private var sharedFetched = false
    /// The household's share has been read from iCloud (it may be nil: never shared). Until
    /// then `participants` is unknown, not empty.
    private(set) var shareLoaded = false
    /// The last problem worth showing, in words.
    private(set) var problem: String?
    /// An invitation waiting for a yes (`hearthHouseholdInvitations()`).
    var pendingInvite: CKShare.Metadata?

    @ObservationIgnored private(set) var app: HearthApp = .caloma
    @ObservationIgnored private var started = false
    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var privateEngine: CKSyncEngine?
    @ObservationIgnored private var sharedEngine: CKSyncEngine?
    /// An app zone syncing on these engines (BigTable's kitchen).
    @ObservationIgnored private var zoneParticipant: (any HearthZoneParticipant)?
    @ObservationIgnored private var systemFields: [String: Data] = [:]
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private var fieldsSaveTask: Task<Void, Never>?
    @ObservationIgnored private let sharingDelegate = HearthHouseholdSharingDelegate()
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.hearth", category: "household")

    /// Whose household this device's Hearth apps are in (nil: their own). Kept in the app
    /// group, so when one app joins or leaves a household the others follow.
    private static let memberOfKey = "hearth.household.memberOf"
    /// Without iCloud: which person this device belongs to (app group, for every app).
    private static let localMeKey = "hearth.household.me"
    private static let groupDefaults = UserDefaults(suiteName: "group.com.stephenwarren.hearth") ?? .standard

    override init() {
        // Builds before the app group held these kept them per app: move them over once.
        for key in [Self.memberOfKey, Self.localMeKey] where Self.groupDefaults.string(forKey: key) == nil {
            if let value = UserDefaults.standard.string(forKey: key) { Self.groupDefaults.set(value, forKey: key) }
        }
        let owner = Self.groupDefaults.string(forKey: Self.memberOfKey)
        mode = owner.map { .member(ownerName: $0) } ?? .owner
        localMeID = Self.groupDefaults.string(forKey: Self.localMeKey)
        super.init()
    }

    private static var sharedMemberOf: String? { groupDefaults.string(forKey: memberOfKey) }

    private func setMemberOf(_ ownerName: String?) {
        for defaults in [Self.groupDefaults, UserDefaults.standard] {
            if let ownerName { defaults.set(ownerName, forKey: Self.memberOfKey) } else { defaults.removeObject(forKey: Self.memberOfKey) }
        }
    }

    private func setLocalMe(_ id: String?) {
        localMeID = id
        for defaults in [Self.groupDefaults, UserDefaults.standard] {
            if let id { defaults.set(id, forKey: Self.localMeKey) } else { defaults.removeObject(forKey: Self.localMeKey) }
        }
    }

    // MARK: - Reading

    var exists: Bool { snapshot.exists }
    var info: HearthHouseholdInfo? { snapshot.info }
    /// Everyone not archived, in order.
    var people: [HearthMember] { snapshot.people }
    var parents: [HearthMember] { people.filter { $0.role != .kid } }
    var kids: [HearthMember] { people.filter { $0.role == .kid } }
    var isMember: Bool { if case .member = mode { true } else { false } }

    func member(_ id: String?) -> HearthMember? { snapshot.member(id) }
    /// The household person linked to an app's own id for them, in the household or on this
    /// device (see `linkHere`).
    func member(app: HearthApp, appID: String) -> HearthMember? {
        if let linked = snapshot.member(app: app, appID: appID) { return linked }
        guard let personID = Self.localLinks(app).first(where: { $0.value == appID })?.key else { return nil }
        return member(personID)
    }

    /// The person this device belongs to: matched by iCloud account, or picked on this device.
    var me: HearthMember? {
        if let myUserID, let mine = people.first(where: { $0.appleUserID == myUserID }) { return mine }
        return member(localMeID)
    }

    var organizer: HearthMember? { member(info?.organizerID) }

    /// Whether this person can change everyone (a parent, the organizer, or nobody's sharing).
    var canEditEveryone: Bool {
        guard exists else { return true }
        if isMember, share?.currentUserParticipant?.permission == .readOnly { return false }
        guard let me else { return !isMember }
        return me.role == .parent || me.id == info?.organizerID
    }

    /// Whether this person can change `member`: parents anyone, adults themselves.
    func canEdit(_ member: HearthMember) -> Bool {
        if canEditEveryone { return true }
        if isMember, share?.currentUserParticipant?.permission == .readOnly { return false }
        return member.id == me?.id && member.role == .adult
    }

    /// People invited who haven't joined yet, and everyone who has.
    var participants: [CKShare.Participant] {
        share?.participants.filter { $0.role != .owner && $0.acceptanceStatus != .removed } ?? []
    }

    var pendingParticipants: [CKShare.Participant] {
        participants.filter { $0.acceptanceStatus == .pending }
    }

    /// Who shared the household, for a member.
    var ownerName: String? {
        guard isMember, let components = share?.owner.userIdentity.nameComponents else { return nil }
        let name = components.formatted(.name(style: .short))
        return name.isEmpty ? nil : name
    }

    /// The household as an AI request needs it. See `HearthHouseholdSnapshot.aiContext`.
    func aiContext() -> HearthAIContext { snapshot.aiContext() }

    // MARK: - Starting

    /// Call once at launch with the app's identity. Safe to call again.
    func start(app: HearthApp) {
        guard !started else { return }
        started = true
        self.app = app
        snapshot = HearthHouseholdSnapshot.onDevice()
        Hearth.startObservingChanges()
        changeObserver = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HearthHouseholdStore.shared.otherAppChanged() }
        }
        guard Self.isCloudEnabled else {
            account = .unavailable
            return
        }
        let container = CKContainer(identifier: Self.containerID)
        self.container = container
        systemFields = HearthHouseholdFiles.loadFields()
        privateEngine = makeEngine(database: container.privateCloudDatabase, state: HearthHouseholdFiles.loadState(.private))
        sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: HearthHouseholdFiles.loadState(.shared))
        // Another Hearth app may have joined or left a household since this one last ran.
        followOtherApps()
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Task { await HearthHouseholdStore.shared.refreshAccount() } }
        }
        Task {
            await refreshAccount()
            await refreshShare()
        }
    }

    /// Off only where the app hasn't got the shared iCloud container yet. Every Hearth app has it.
    static let isCloudEnabled = true

    private func makeEngine(database: CKDatabase, state: CKSyncEngine.State.Serialization?) -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: self)
        configuration.automaticallySync = true
        return CKSyncEngine(configuration)
    }

    private var activeEngine: CKSyncEngine? { isMember ? sharedEngine : privateEngine }

    private var zoneID: CKRecordZone.ID {
        switch mode {
        case .owner: CKRecordZone.ID(zoneName: Self.zoneName)
        case .member(let ownerName): CKRecordZone.ID(zoneName: Self.zoneName, ownerName: ownerName)
        }
    }

    func refreshAccount() async {
        guard let container else { return }
        do {
            account = switch try await container.accountStatus() {
            case .available: .available
            case .noAccount: .noAccount
            default: .unavailable
            }
        } catch {
            account = .unavailable
        }
        if account == .available, myUserID == nil {
            myUserID = try? await container.userRecordID().recordName
            claimMyRecordIfNeeded()
        }
    }

    /// Sends what's waiting and fetches the latest. For pull to refresh; never throws.
    func refresh() async {
        guard let engine = activeEngine, account == .available else { return }
        do { try await engine.sendChanges() } catch { note(error) }
        do { try await engine.fetchChanges(.init(scope: .zoneIDs(fetchZones(isShared: isMember)))) } catch { note(error) }
    }

    /// Another Hearth app on this device saved its copy: take in what's newer.
    private func otherAppChanged() {
        followOtherApps()
        let groupMe = Self.groupDefaults.string(forKey: Self.localMeKey)
        if groupMe != localMeID { localMeID = groupMe }
        let merged = HearthHouseholdSnapshot.merged([snapshot] + Hearth.readAll(HearthHouseholdSnapshot.self).map(\.value))
        guard merged != snapshot else { return }
        let joinedElsewhere = merged.info?.id != snapshot.info?.id
        snapshot = merged
        if joinedElsewhere { Task { await refreshShare() } }
    }

    /// Joins or leaves with the other Hearth apps: when another app on this device joined a
    /// household (or left one), this app's sync moves to the same place, keeping the people
    /// the app group already has. Without it, this app would upload one household's people
    /// into another's zone.
    private func followOtherApps() {
        let shared = Self.sharedMemberOf
        let current: String? = if case .member(let ownerName) = mode { ownerName } else { nil }
        guard shared != current, let container else { return }
        log.notice("Following another Hearth app to a different household")
        UserDefaults.standard.set(shared, forKey: Self.memberOfKey)
        mode = shared.map { .member(ownerName: $0) } ?? .owner
        share = nil
        systemFields = [:]
        HearthHouseholdFiles.saveFields(systemFields)
        if shared == nil {
            HearthHouseholdFiles.saveState(nil, .private)
            privateEngine = makeEngine(database: container.privateCloudDatabase, state: nil)
        } else {
            HearthHouseholdFiles.saveState(nil, .shared)
            sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: nil)
        }
        if shared == nil { privateFetched = false } else { sharedFetched = false }
        shareLoaded = false
        zoneParticipant?.zoneEngineReset(isShared: shared != nil)
        Task {
            try? await activeEngine?.fetchChanges()
            await refreshShare()
        }
    }

    // MARK: - An app's own zone

    /// Lets an app sync a zone of its own on the household's engines (an app never runs two
    /// engines on one database). BigTable's kitchen uses it. Call before `start(app:)`.
    func register(_ participant: any HearthZoneParticipant) {
        zoneParticipant = participant
    }

    /// The Hearth iCloud container, once started.
    var cloudContainer: CKContainer? { container }

    /// Queues the participant's changes on the engine for its zone's database.
    func queueZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange], isShared: Bool) {
        guard !changes.isEmpty, let engine = isShared ? sharedEngine : privateEngine else { return }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    /// Makes sure a zone of the participant's exists in this account's private database.
    func ensurePrivateZone(_ zoneID: CKRecordZone.ID) {
        privateEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    /// Sends and fetches the participant's database now (pull to refresh).
    func syncZoneNow(isShared: Bool) async {
        guard let engine = isShared ? sharedEngine : privateEngine, account == .available else { return }
        do { try await engine.sendChanges() } catch { note(error) }
        do { try await engine.fetchChanges(.init(scope: .zoneIDs(fetchZones(isShared: isShared)))) } catch { note(error) }
    }

    // MARK: - Changing

    /// Creates the household (first-time setup): its name and its people. The person creating it
    /// is its organizer; on this device they're `me`.
    func create(name: String, members: [HearthMember], organizerID: String?, restrictions: [String] = []) {
        // Never over a household this account joined (its record is the family's).
        guard !isMember else { return }
        let now = Date.now
        var people = members
        for index in people.indices {
            people[index].sortOrder = index
            people[index].updatedAt = now
            if people[index].id == organizerID, let myUserID { people[index].appleUserID = myUserID }
        }
        let info = HearthHouseholdInfo(name: name, restrictions: restrictions, organizerID: organizerID, updatedAt: now)
        snapshot = HearthHouseholdSnapshot(info: info, members: people, adoptedAt: now)
        if let organizerID, myUserID == nil { setLocalMe(organizerID) }
        publish()
        if !isMember, let privateEngine {
            privateEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        queueSaves([Self.householdRecordName] + people.map { Self.memberPrefix + $0.id })
    }

    /// Saves a new or changed person.
    func save(_ member: HearthMember) {
        var updated = member
        updated.updatedAt = .now
        if let index = snapshot.members.firstIndex(where: { $0.id == member.id }) {
            guard !snapshot.members[index].sameContent(as: member) else { return }
            snapshot.members[index] = updated
        } else {
            updated.sortOrder = (snapshot.members.map(\.sortOrder).max() ?? -1) + 1
            snapshot.members.append(updated)
        }
        snapshot.deleted[member.id] = nil
        publish()
        queueSaves([Self.memberPrefix + member.id])
    }

    /// Hides someone everywhere; their history stays in each app.
    func archive(_ id: String, archived: Bool = true) {
        guard var member = member(id) else { return }
        member.isArchived = archived
        save(member)
    }

    /// Removes someone for good: their record, photo and every app's link to them.
    func delete(_ id: String) {
        snapshot.members.removeAll { $0.id == id }
        snapshot.deleted[id] = .now
        publish()
        let recordID = CKRecord.ID(recordName: Self.memberPrefix + id, zoneID: zoneID)
        systemFields[recordID.recordName] = nil
        activeEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        scheduleFieldsSave()
    }

    /// Folds people who are plainly the same person into one: the same full name, both kids or
    /// both grown-ups, and no two different birthdays or Apple Accounts. The one kept is the
    /// organizer, then whoever has joined with their own Apple Account, then the fullest record;
    /// ties go to the lower id, so every device picks the same one. It takes the others'
    /// birthday, photo, food and app links, and becomes "me" here if one of them was. Only for
    /// someone who can change everyone. Returns how many were folded in.
    @discardableResult
    func mergeDuplicates() -> Int {
        guard exists, hasLoaded, canEditEveryone else { return 0 }
        let groups = Dictionary(grouping: snapshot.members.filter { !$0.isArchived && !$0.trimmedName.isEmpty }) {
            HearthNames.normalized($0.name) + ($0.role == .kid ? "|kid" : "|adult")
        }
        var folded = 0
        for group in groups.values where group.count > 1 {
            guard Set(group.compactMap(\.birthday)).count <= 1,
                  Set(group.compactMap(\.appleUserID)).count <= 1 else { continue }
            let ordered = group.sorted { lhs, rhs in
                let a = mergeRank(lhs), b = mergeRank(rhs)
                return a != b ? a > b : lhs.id < rhs.id
            }
            var keep = ordered[0]
            for other in ordered.dropFirst() {
                keep = Self.fold(other, into: keep)
                if snapshot.info?.organizerID == other.id {
                    snapshot.info?.organizerID = keep.id
                    snapshot.info?.updatedAt = .now
                    queueSaves([Self.householdRecordName])
                }
                if localMeID == other.id { setLocalMe(keep.id) }
                delete(other.id)
                folded += 1
            }
            save(keep)
        }
        if folded > 0 { log.notice("Folded \(folded) duplicate people") }
        return folded
    }

    private func mergeRank(_ member: HearthMember) -> Int {
        var rank = 0
        if member.id == info?.organizerID { rank += 100 }
        if member.appleUserID != nil { rank += 50 }
        if member.birthday != nil { rank += 4 }
        if member.photo != nil { rank += 4 }
        rank += member.appIDs.count
        rank += min(member.allergies.count + member.diet.count + member.likes.count + member.dislikes.count, 3)
        return rank
    }

    private static func fold(_ other: HearthMember, into keep: HearthMember) -> HearthMember {
        func union(_ a: [String], _ b: [String]) -> [String] {
            var seen = Set(a.map { $0.lowercased() })
            return a + b.filter { seen.insert($0.lowercased()).inserted }
        }
        var merged = keep
        merged.birthday = keep.birthday ?? other.birthday
        merged.photo = keep.photo ?? other.photo
        merged.appleUserID = keep.appleUserID ?? other.appleUserID
        merged.allergies = union(keep.allergies, other.allergies)
        merged.diet = union(keep.diet, other.diet)
        merged.likes = union(keep.likes, other.likes)
        merged.dislikes = union(keep.dislikes, other.dislikes)
        for (app, id) in other.appIDs where merged.appIDs[app] == nil { merged.appIDs[app] = id }
        if keep.role == .adult && other.role == .parent { merged.role = .parent }
        if keep.trimmedName.count < other.trimmedName.count { merged.name = other.trimmedName }
        merged.sortOrder = min(keep.sortOrder, other.sortOrder)
        return merged
    }

    /// Records the id an app uses for someone, so the app can find them again.
    func link(_ memberID: String, app: HearthApp, appID: String) {
        guard var member = member(memberID), member.appIDs[app.rawValue] != appID else { return }
        member.appIDs[app.rawValue] = appID
        save(member)
    }

    // MARK: Links on this device

    // An app's data may be shared by the whole family (Caloma's family, a shared Suffice budget)
    // or kept per person (two separate budgets). The household's `appIDs` holds the shared
    // link; a phone whose app has its own copy of someone keeps its link here instead, so two
    // phones never take turns overwriting it.

    /// `person`'s id in `app` on this device, among the ids the app has here.
    func localID(of person: HearthMember, app: HearthApp, among ids: Set<String>) -> String? {
        if let id = person.appID(app), ids.contains(id) { return id }
        if let id = Self.localLinks(app)[person.id], ids.contains(id) { return id }
        return nil
    }

    /// Links `person` to the app's id for them: in the household when nobody's linked yet,
    /// otherwise on this device only.
    func linkHere(_ person: HearthMember, app: HearthApp, localID: String) {
        var links = Self.localLinks(app)
        if person.appID(app) == nil {
            link(person.id, app: app, appID: localID)
            links[person.id] = nil
        } else if person.appID(app) != localID {
            links[person.id] = localID
        } else {
            links[person.id] = nil
        }
        UserDefaults.standard.set(links, forKey: Self.localLinksKey(app))
    }

    /// Whether the app's id `localID` belongs to someone in the household, on this device.
    func isLinked(app: HearthApp, localID: String) -> Bool {
        member(app: app, appID: localID) != nil
    }

    private static func localLinksKey(_ app: HearthApp) -> String { "hearth.household.links.\(app.rawValue)" }

    private static func localLinks(_ app: HearthApp) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: localLinksKey(app)) as? [String: String] ?? [:]
    }

    func updateInfo(name: String? = nil, restrictions: [String]? = nil, joinCode: String? = nil, appShare: (app: HearthApp, url: String)? = nil) {
        guard var info = snapshot.info else { return }
        if let name { info.name = name }
        if let restrictions { info.restrictions = restrictions }
        if let joinCode { info.joinCode = joinCode }
        if let appShare { info.appShareURLs[appShare.app.rawValue] = appShare.url }
        guard info != snapshot.info else { return }
        info.updatedAt = .now
        snapshot.info = info
        publish()
        queueSaves([Self.householdRecordName])
    }

    /// Puts people in this order.
    func reorder(_ ids: [String]) {
        var changed: [String] = []
        for (index, id) in ids.enumerated() {
            guard let at = snapshot.members.firstIndex(where: { $0.id == id }), snapshot.members[at].sortOrder != index else { continue }
            snapshot.members[at].sortOrder = index
            snapshot.members[at].updatedAt = .now
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        snapshot.members.sort { $0.sortOrder < $1.sortOrder }
        publish()
        queueSaves(changed.map { Self.memberPrefix + $0 })
    }

    /// "This is me": marks someone as the person on this device (and in this iCloud account).
    func claim(_ memberID: String) {
        setLocalMe(memberID)
        guard let myUserID else { return }
        for other in snapshot.members where other.appleUserID == myUserID && other.id != memberID {
            var cleared = other
            cleared.appleUserID = nil
            save(cleared)
        }
        guard var member = member(memberID), member.appleUserID != myUserID else { return }
        member.appleUserID = myUserID
        save(member)
    }

    /// Once the iCloud account is known: the person picked on this device gets it.
    private func claimMyRecordIfNeeded() {
        guard exists, let myUserID, !people.contains(where: { $0.appleUserID == myUserID }),
              let local = localMeID, member(local) != nil else { return }
        claim(local)
    }

    private func publish() {
        Hearth.publish(snapshot, from: app)
        if snapshot.exists { HearthHouseholdPhotos.clean(keeping: Set(snapshot.members.compactMap(\.photo))) }
    }

    private func queueSaves(_ recordNames: [String]) {
        guard let engine = activeEngine, exists else { return }
        engine.state.add(pendingRecordZoneChanges: recordNames.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === privateEngine || syncEngine === sharedEngine else { return }
        let isPrivate = syncEngine === privateEngine
        switch event {
        case .stateUpdate(let update):
            HearthHouseholdFiles.saveState(update.stateSerialization, isPrivate ? .private : .shared)
        case .accountChange(let change):
            if isPrivate { handleAccountChange(change) }
        case .fetchedDatabaseChanges(let changes):
            handleDatabaseChanges(changes, isPrivate: isPrivate)
        case .fetchedRecordZoneChanges(let changes):
            handleZoneChanges(changes, isPrivate: isPrivate)
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: syncEngine, isPrivate: isPrivate)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves { note(failure.error) }
        case .willFetchChanges, .willSendChanges:
            isSyncing = true
        case .didFetchChanges:
            isSyncing = false
            if isPrivate { privateFetched = true } else { sharedFetched = true }
        case .didSendChanges:
            isSyncing = false
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await HearthHouseholdStore.shared.record(for: recordID, engine: syncEngine)
        }
    }

    /// Only the zones this app uses: the household's, and its own app zone. Other apps never
    /// download BigTable's recipes.
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs(fetchZones(isShared: syncEngine === sharedEngine))
        return options
    }

    private func fetchZones(isShared: Bool) -> [CKRecordZone.ID] {
        var zones: [CKRecordZone.ID] = isShared == isMember ? [zoneID] : []
        if let location = zoneParticipant?.zoneLocation, location.isShared == isShared { zones.append(location.zoneID) }
        return zones
    }

    /// The participant's zone, when it's in this engine's database.
    private func participantZone(isShared: Bool) -> CKRecordZone.ID? {
        guard let location = zoneParticipant?.zoneLocation, location.isShared == isShared else { return nil }
        return location.zoneID
    }

    /// The record to upload, built from the household as it is now.
    private func record(for recordID: CKRecord.ID, engine: CKSyncEngine) -> CKRecord? {
        if let zone = participantZone(isShared: engine === sharedEngine), recordID.zoneID == zone {
            guard let record = zoneParticipant?.zoneRecord(for: recordID) else {
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return record
        }
        let name = recordID.recordName
        let record: CKRecord
        if name == Self.householdRecordName, let info = snapshot.info {
            record = cachedRecord(recordID) ?? CKRecord(recordType: "Household", recordID: recordID)
            HearthHouseholdRecords.write(info, to: record)
        } else if name.hasPrefix(Self.memberPrefix), let member = member(String(name.dropFirst(Self.memberPrefix.count))) {
            record = cachedRecord(recordID) ?? CKRecord(recordType: "HouseholdMember", recordID: recordID)
            HearthHouseholdRecords.write(member, to: record)
        } else {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        return record
    }

    private func handleZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, isPrivate: Bool) {
        if let zone = participantZone(isShared: !isPrivate) {
            let modifications = changes.modifications.map(\.record).filter { $0.recordID.zoneID == zone }
            let deletions = changes.deletions.filter { $0.recordID.zoneID == zone }
            if !modifications.isEmpty || !deletions.isEmpty {
                zoneParticipant?.zoneFetched(modifications: modifications, deletions: deletions)
            }
        }
        guard isPrivate != isMember else { return }
        let zone = zoneID
        let modifications = changes.modifications.map(\.record).filter { $0.recordID.zoneID == zone }
        let deletions = changes.deletions.filter { $0.recordID.zoneID == zone }
        guard !modifications.isEmpty || !deletions.isEmpty else { return }

        var next = snapshot
        for record in modifications {
            cache(record)
            if record.recordType == "Household" {
                let info = HearthHouseholdRecords.info(from: record)
                if next.info == nil || info.updatedAt > (next.info?.updatedAt ?? .distantPast) || next.info?.id != info.id {
                    if next.info?.id != info.id { next.adoptedAt = .now }
                    next.info = info
                }
            } else if record.recordType == "HouseholdMember", let incoming = HearthHouseholdRecords.member(from: record, existing: next.members) {
                if let index = next.members.firstIndex(where: { $0.id == incoming.id }) {
                    if incoming.updatedAt > next.members[index].updatedAt { next.members[index] = incoming }
                } else if incoming.updatedAt > (next.deleted[incoming.id] ?? .distantPast) {
                    next.members.append(incoming)
                }
            }
        }
        for deletion in deletions {
            systemFields[deletion.recordID.recordName] = nil
            let name = deletion.recordID.recordName
            if name.hasPrefix(Self.memberPrefix) {
                let id = String(name.dropFirst(Self.memberPrefix.count))
                next.members.removeAll { $0.id == id }
                next.deleted[id] = .now
            }
        }
        next.members.sort { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        next.isShared = isMember || share != nil
        if next != snapshot {
            snapshot = next
            publish()
            claimMyRecordIfNeeded()
            mergeDuplicates()
        }
        scheduleFieldsSave()
    }

    private func handleDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges, isPrivate: Bool) {
        if let participant = zoneParticipant {
            let added = changes.modifications.map(\.zoneID).filter { $0.zoneName == participant.zoneName }
            let deleted = changes.deletions.filter { $0.zoneID.zoneName == participant.zoneName }
            if !added.isEmpty || !deleted.isEmpty {
                participant.zoneDatabaseChanged(added: added, deleted: deleted, isShared: !isPrivate)
            }
        }
        if isPrivate {
            for deletion in changes.deletions where deletion.zoneID.zoneName == Self.zoneName && !isMember {
                systemFields = [:]
                HearthHouseholdFiles.saveFields(systemFields)
                share = nil
                if deletion.reason == .encryptedDataReset, exists {
                    // The iCloud keys were reset: put back what's on this device.
                    privateEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    queueSaves([Self.householdRecordName] + snapshot.members.map { Self.memberPrefix + $0.id })
                }
            }
            return
        }
        for deletion in changes.deletions where deletion.zoneID == zoneID && isMember {
            log.notice("The household was stopped or left")
            returnToOwnHousehold()
        }
        if !isMember, let joined = changes.modifications.first(where: { $0.zoneID.zoneName == Self.zoneName }) {
            // Joined in another app or on another device.
            becomeMember(ownerName: joined.zoneID.ownerName)
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine, isPrivate: Bool) {
        let appZone = participantZone(isShared: !isPrivate)
        if let appZone, let participant = zoneParticipant {
            let retries = participant.zoneSent(
                saved: sent.savedRecords.filter { $0.recordID.zoneID == appZone },
                deleted: sent.deletedRecordIDs.filter { $0.zoneID == appZone },
                failedSaves: sent.failedRecordSaves.filter { $0.record.recordID.zoneID == appZone },
                isShared: !isPrivate
            )
            if !retries.isEmpty { engine.state.add(pendingRecordZoneChanges: retries) }
        }
        for record in sent.savedRecords where record.recordID.zoneID != appZone { cache(record) }
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in sent.failedRecordSaves where failure.record.recordID.zoneID != appZone {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone saved first. Theirs is newer only if its own clock says so.
                if let server = failure.error.serverRecord {
                    cache(server)
                    if server.recordType == "HouseholdMember", let theirs = HearthHouseholdRecords.member(from: server, existing: snapshot.members),
                       let index = snapshot.members.firstIndex(where: { $0.id == theirs.id }),
                       theirs.updatedAt > snapshot.members[index].updatedAt {
                        snapshot.members[index] = theirs
                        publish()
                        continue
                    }
                }
                retry.append(.saveRecord(recordID))
            case .zoneNotFound:
                if isPrivate {
                    engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
                    systemFields[recordID.recordName] = nil
                    retry.append(.saveRecord(recordID))
                } else {
                    returnToOwnHousehold()
                    return
                }
            case .unknownItem:
                systemFields[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
            case .batchRequestFailed:
                retry.append(.saveRecord(recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited, .notAuthenticated, .operationCancelled, .accountTemporarilyUnavailable:
                break
            default:
                note(failure.error)
            }
        }
        if !retry.isEmpty { engine.state.add(pendingRecordZoneChanges: retry) }
        if sent.failedRecordSaves.isEmpty { problem = nil }
        scheduleFieldsSave()
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            Task { await refreshAccount() }
        case .signOut, .switchAccounts:
            // Someone else's household never stays on a device after its account leaves.
            if isMember {
                snapshot = HearthHouseholdSnapshot(info: nil, members: [], adoptedAt: .now)
                publish()
            }
            setMemberOf(nil)
            setLocalMe(nil)
            mode = .owner
            share = nil
            myUserID = nil
            systemFields = [:]
            HearthHouseholdFiles.removeAll()
            zoneParticipant?.zoneAccountDidChange()
            if let container {
                privateEngine = makeEngine(database: container.privateCloudDatabase, state: nil)
                sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: nil)
                privateFetched = false
                sharedFetched = false
                shareLoaded = false
                zoneParticipant?.zoneEngineReset(isShared: false)
                zoneParticipant?.zoneEngineReset(isShared: true)
            }
            Task { await refreshAccount() }
        @unknown default:
            break
        }
    }

    // MARK: - Sharing (organizer)

    private func prepareShare() async throws -> CKShare {
        if let share { return share }
        guard let container else { throw CKError(.notAuthenticated) }
        let database = container.privateCloudDatabase
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let newShare = CKShare(recordZoneID: zoneID)
        newShare[CKShare.SystemFieldKey.title] = (info?.name ?? "Hearth Household") as CKRecordValue
        newShare.publicPermission = .none
        let result = try await database.modifyRecords(saving: [newShare], deleting: [])
        guard let saved = try result.saveResults[newShare.recordID]?.get() as? CKShare else {
            throw CKError(.internalError)
        }
        share = saved
        snapshot.isShared = true
        publish()
        return saved
    }

    func refreshShare() async {
        guard let container, exists || isMember else { return }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let database = isMember ? container.sharedCloudDatabase : container.privateCloudDatabase
        do {
            share = try await database.record(for: shareID) as? CKShare
            shareLoaded = true
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            share = nil
            shareLoaded = true
        } catch {
            log.error("Couldn't check the household share: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Apple's sheet for inviting someone: `role` decides whether they can edit (parents and
    /// adults) or only see (kids).
    func presentInvite(as role: HearthRole) async {
        guard account == .available else {
            problem = "Sign in to iCloud in Settings to invite your family."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try? await privateEngine?.sendChanges()
            let share = try await prepareShare()
            guard let container else { return }
            let controller = UICloudSharingController(share: share, container: container)
            controller.availablePermissions = role == .kid ? [.allowReadOnly, .allowPrivate] : [.allowReadWrite, .allowPrivate]
            controller.delegate = sharingDelegate
            controller.modalPresentationStyle = .formSheet
            UIApplication.shared.hearthTopViewController?.present(controller, animated: true)
        } catch {
            note(error)
        }
    }

    fileprivate func sharingChanged() {
        Task { await refreshShare() }
    }

    // MARK: - Joining and leaving (member)

    /// Whether an invitation is to the Hearth household (and not an app's own sharing).
    nonisolated static func handles(_ metadata: CKShare.Metadata) -> Bool {
        metadata.containerIdentifier == containerID && metadata.share.recordID.zoneID.zoneName == zoneName
    }

    /// From the app's scene delegate, for invitations to this container.
    func receive(_ metadata: CKShare.Metadata) {
        guard metadata.participantRole != .owner else { return }
        if case .member(let ownerName) = mode, ownerName == metadata.share.recordID.zoneID.ownerName { return }
        pendingInvite = metadata
    }

    var inviterName: String {
        guard let components = pendingInvite?.ownerIdentity.nameComponents else { return "your family" }
        let name = components.formatted(.name(style: .short))
        return name.isEmpty ? "your family" : name
    }

    /// Joins the pending invitation's household. This device's own household stays in this
    /// person's iCloud and comes back if they leave.
    func acceptInvite() async {
        guard let metadata = pendingInvite, let container else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try? await privateEngine?.sendChanges()
            _ = try await container.accept(metadata)
        } catch {
            note(error)
            return
        }
        pendingInvite = nil
        becomeMember(ownerName: metadata.share.recordID.zoneID.ownerName)
    }

    /// Leaves the household this account joined.
    func leave() async {
        guard isMember, let container else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await container.sharedCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
        } catch {
            note(error)
            return
        }
        returnToOwnHousehold()
    }

    private func becomeMember(ownerName: String) {
        guard mode != .member(ownerName: ownerName), let container else { return }
        log.notice("Joining a shared household")
        setMemberOf(ownerName)
        setLocalMe(nil)
        mode = .member(ownerName: ownerName)
        share = nil
        snapshot = HearthHouseholdSnapshot(info: nil, members: [], isShared: true, adoptedAt: .now)
        publish()
        systemFields = [:]
        HearthHouseholdFiles.saveFields(systemFields)
        HearthHouseholdFiles.saveState(nil, .shared)
        sharedEngine = makeEngine(database: container.sharedCloudDatabase, state: nil)
        sharedFetched = false
        shareLoaded = false
        zoneParticipant?.zoneEngineReset(isShared: true)
        Task {
            try? await sharedEngine?.fetchChanges()
            await refreshShare()
        }
    }

    private func returnToOwnHousehold() {
        guard isMember, let container else { return }
        setMemberOf(nil)
        setLocalMe(nil)
        mode = .owner
        share = nil
        snapshot = HearthHouseholdSnapshot(info: nil, members: [], adoptedAt: .now)
        publish()
        systemFields = [:]
        HearthHouseholdFiles.saveFields(systemFields)
        HearthHouseholdFiles.saveState(nil, .private)
        privateEngine = makeEngine(database: container.privateCloudDatabase, state: nil)
        privateFetched = false
        shareLoaded = false
        zoneParticipant?.zoneEngineReset(isShared: false)
        Task {
            try? await privateEngine?.fetchChanges()
            await refreshShare()
        }
    }

    // MARK: - Helpers

    private func cache(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        systemFields[record.recordID.recordName] = coder.encodedData
    }

    private func cachedRecord(_ recordID: CKRecord.ID) -> CKRecord? {
        guard let data = systemFields[recordID.recordName],
              let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordID.zoneID == recordID.zoneID else { return nil }
        return record
    }

    private func scheduleFieldsSave() {
        fieldsSaveTask?.cancel()
        fieldsSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            HearthHouseholdFiles.saveFields(systemFields)
        }
    }

    private func note(_ error: Error) {
        log.error("Household sync: \(error.localizedDescription, privacy: .public)")
        if let error = error as? CKError {
            switch error.code {
            case .networkUnavailable, .networkFailure, .operationCancelled:
                return
            case .notAuthenticated:
                problem = "Sign in to iCloud in Settings to share your household."
            case .quotaExceeded:
                problem = "Your iCloud storage is full."
            case .participantMayNeedVerification:
                problem = "Open the invitation in Messages or Mail on this device to verify it, then try again."
            default:
                problem = error.localizedDescription
            }
        } else {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Records

/// Household and member records, field by field. Food and birthdays go in `encryptedValues`.
nonisolated enum HearthHouseholdRecords {
    static func write(_ info: HearthHouseholdInfo, to record: CKRecord) {
        record["householdID"] = info.id as NSString
        record["name"] = info.name as NSString
        record["organizerID"] = info.organizerID.map { $0 as NSString }
        record["updatedAt"] = info.updatedAt as NSDate
        record.encryptedValues["restrictions"] = info.restrictions as NSArray
        record.encryptedValues["joinCode"] = info.joinCode.map { $0 as NSString }
        record.encryptedValues["appShareURLs"] = (try? JSONEncoder().encode(info.appShareURLs)).flatMap { String(data: $0, encoding: .utf8) }.map { $0 as NSString }
    }

    static func info(from record: CKRecord) -> HearthHouseholdInfo {
        HearthHouseholdInfo(
            id: record["householdID"] as? String ?? record.recordID.zoneID.ownerName,
            name: record["name"] as? String ?? "Household",
            restrictions: record.encryptedValues["restrictions"] as? [String] ?? [],
            organizerID: record["organizerID"] as? String,
            updatedAt: record["updatedAt"] as? Date ?? record.modificationDate ?? .distantPast,
            joinCode: record.encryptedValues["joinCode"] as? String,
            appShareURLs: (record.encryptedValues["appShareURLs"] as? String)
                .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        )
    }

    static func write(_ member: HearthMember, to record: CKRecord) {
        record["name"] = member.name as NSString
        record["role"] = member.role.rawValue as NSString
        record["colorHex"] = NSNumber(value: member.colorHex)
        record["sortOrder"] = NSNumber(value: member.sortOrder)
        record["isArchived"] = NSNumber(value: member.isArchived)
        record["appleUserID"] = member.appleUserID.map { $0 as NSString }
        record["appIDs"] = (try? String(data: JSONEncoder().encode(member.appIDs), encoding: .utf8)).map { $0 as NSString }
        record["updatedAt"] = member.updatedAt as NSDate
        record.encryptedValues["birthday"] = member.birthday.map { $0 as NSString }
        record.encryptedValues["allergies"] = member.allergies as NSArray
        record.encryptedValues["diet"] = member.diet as NSArray
        record.encryptedValues["likes"] = member.likes as NSArray
        record.encryptedValues["dislikes"] = member.dislikes as NSArray
        // The photo's file name is derived from its bytes, so every device stores it under
        // the same name and only downloads it once.
        record["photoName"] = member.photo.map { $0 as NSString }
        if let name = member.photo, let data = Hearth.photo(named: name) {
            let url = FileManager.default.temporaryDirectory.appending(path: "hearth-\(member.id).jpg", directoryHint: .notDirectory)
            try? data.write(to: url, options: .atomic)
            record["photo"] = CKAsset(fileURL: url)
        } else {
            record["photo"] = nil
        }
    }

    /// A member from iCloud. Its photo is copied into the shared folder unless this device
    /// already has it.
    static func member(from record: CKRecord, existing: [HearthMember]) -> HearthMember? {
        let name = record.recordID.recordName
        guard name.hasPrefix("member-") else { return nil }
        let id = String(name.dropFirst("member-".count))
        var appIDs: [String: String] = [:]
        if let json = record["appIDs"] as? String, let data = json.data(using: .utf8) {
            appIDs = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        var photo: String?
        if let remoteName = record["photoName"] as? String {
            if Hearth.photo(named: remoteName) != nil {
                photo = remoteName
            } else if let asset = record["photo"] as? CKAsset, let url = asset.fileURL,
                      let data = try? Data(contentsOf: url) {
                photo = HearthHouseholdPhotos.store(data, name: remoteName)
            } else {
                photo = existing.first { $0.id == id }?.photo
            }
        }
        return HearthMember(
            id: id,
            name: record["name"] as? String ?? "",
            role: HearthRole(rawValue: record["role"] as? String ?? "") ?? .adult,
            colorHex: (record["colorHex"] as? NSNumber)?.uint32Value ?? 0x0A7AFF,
            photo: photo,
            birthday: record.encryptedValues["birthday"] as? String,
            allergies: record.encryptedValues["allergies"] as? [String] ?? [],
            diet: record.encryptedValues["diet"] as? [String] ?? [],
            likes: record.encryptedValues["likes"] as? [String] ?? [],
            dislikes: record.encryptedValues["dislikes"] as? [String] ?? [],
            appleUserID: record["appleUserID"] as? String,
            appIDs: appIDs,
            isArchived: (record["isArchived"] as? NSNumber)?.boolValue ?? false,
            sortOrder: (record["sortOrder"] as? NSNumber)?.intValue ?? 0,
            updatedAt: record["updatedAt"] as? Date ?? record.modificationDate ?? .distantPast
        )
    }
}

// MARK: - Saved state

/// What the store keeps between launches, in this app's Application Support/HearthHousehold.
nonisolated enum HearthHouseholdFiles {
    nonisolated enum Engine: String { case `private`, shared }

    private static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "HearthHousehold", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func loadState(_ engine: Engine) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: folder.appending(path: "\(engine.rawValue).state")) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    static func saveState(_ state: CKSyncEngine.State.Serialization?, _ engine: Engine) {
        let url = folder.appending(path: "\(engine.rawValue).state")
        guard let state, let data = try? JSONEncoder().encode(state) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    static func loadFields() -> [String: Data] {
        guard let data = try? Data(contentsOf: folder.appending(path: "systemFields.plist")) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    static func saveFields(_ fields: [String: Data]) {
        guard let data = try? PropertyListEncoder().encode(fields) else { return }
        try? data.write(to: folder.appending(path: "systemFields.plist"), options: .atomic)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}

// MARK: - Sharing controller

private final class HearthHouseholdSharingDelegate: NSObject, UICloudSharingControllerDelegate {
    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        Logger(subsystem: "com.stephenwarren.hearth", category: "household")
            .error("Sharing failed: \(error.localizedDescription, privacy: .public)")
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        HearthHouseholdStore.shared.info?.name ?? "Hearth Household"
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        HearthHouseholdStore.shared.sharingChanged()
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        HearthHouseholdStore.shared.sharingChanged()
    }
}

/// The scene delegate for apps that share nothing in iCloud of their own (BigTable, Sated):
/// household invitations tapped in Messages or Mail land here.
final class HearthHouseholdSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata, HearthHouseholdStore.handles(metadata) {
            HearthHouseholdStore.shared.receive(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        if HearthHouseholdStore.handles(cloudKitShareMetadata) {
            HearthHouseholdStore.shared.receive(cloudKitShareMetadata)
        }
    }
}

extension UIApplication {
    /// The view controller on top of the foreground window, to present from.
    var hearthTopViewController: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let window = (active + scenes).flatMap(\.windows).first(where: \.isKeyWindow) ?? (active + scenes).first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - App zones

/// A zone of an app's own that syncs on the household's engines. The store fetches only the
/// household's zone and the participant's, and hands over everything for the participant's.
@MainActor
protocol HearthZoneParticipant: AnyObject {
    /// The zone's name ("Kitchen"), to recognise it in database changes.
    var zoneName: String { get }
    /// Where the zone is now: this account's private database, or shared with it. Nil: none.
    var zoneLocation: (zoneID: CKRecordZone.ID, isShared: Bool)? { get }
    /// The record to upload for a pending save, or nil when it no longer exists.
    func zoneRecord(for recordID: CKRecord.ID) -> CKRecord?
    func zoneFetched(modifications: [CKRecord], deletions: [CKDatabase.RecordZoneChange.Deletion])
    /// Returns the changes to try again.
    func zoneSent(saved: [CKRecord], deleted: [CKRecord.ID], failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave], isShared: Bool) -> [CKSyncEngine.PendingRecordZoneChange]
    /// Zones with the participant's name appeared in, or went from, a database.
    func zoneDatabaseChanged(added: [CKRecordZone.ID], deleted: [CKDatabase.DatabaseChange.Deletion], isShared: Bool)
    /// An engine started over (joining or leaving a household, a new account): queue what lives
    /// in that database again.
    func zoneEngineReset(isShared: Bool)
    /// The iCloud account signed out or changed: drop what belonged to the old one.
    func zoneAccountDidChange()
}
