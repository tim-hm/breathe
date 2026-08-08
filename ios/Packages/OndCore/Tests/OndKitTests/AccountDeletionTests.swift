import Foundation
@testable import OndKit
import os
import Testing

/// A server that erases on demand, or refuses to.
///
/// Only the deletion is modelled: `signIn` is unreachable from every test here
/// and pinned in `AccountModelTests` besides.
private final class ErasingAccounts: AccountSyncing {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    private let failure: (any Error)?

    init(failingWith failure: (any Error)? = nil) {
        self.failure = failure
    }

    /// How many erasures actually reached the server.
    var deletions: Int {
        state.withLock { $0 }
    }

    func signIn(identityToken _: String) async throws -> UUID {
        throw AccountRepositoryError.transport("not what this suite is about")
    }

    func delete() async throws {
        if let failure {
            throw failure
        }

        state.withLock { $0 += 1 }
    }
}

/// A profile server that holds nothing and accepts everything, so the store
/// under test behaves exactly as it does on a device that has been online.
private struct SettledProfiles: ProfileSyncing {
    func fetch() async throws -> Profile {
        .unanswered
    }

    @discardableResult
    func update(_ profile: Profile) async throws -> Profile {
        profile
    }
}

/// `StoreKit` with one live subscription on it, which is the state that makes
/// the interesting assertion possible: the account goes, the subscription does
/// not.
private struct SubscribedStoreFront: StoreFront {
    func products() async -> [SubscriptionProduct] {
        []
    }

    func currentEntitlements() async -> [SubscriptionTransaction] {
        [
            SubscriptionTransaction(
                id: 1,
                productID: SubscriptionTier.coach.productIdentifier ?? "",
                expirationDate: .distantFuture,
                revocationDate: nil,
                jws: "jws-coach"
            ),
        ]
    }

    func updates() -> AsyncStream<SubscriptionTransaction> {
        AsyncStream { $0.finish() }
    }

    func purchase(_: SubscriptionTier) async throws -> PurchaseOutcome {
        .cancelled
    }

    func restore() async throws {}
}

/// Records the transactions the client pushes, which is how a test sees the
/// entitlement being re-claimed under the identity that replaced the erased one.
private final class RecordingEntitlements: EntitlementSyncing {
    private let state = OSAllocatedUnfairLock(initialState: 0)

    var submissions: Int {
        state.withLock { $0 }
    }

    func submit(_: String) async throws {
        state.withLock { $0 += 1 }
    }
}

/// Health that has nothing to say, because none of this is about what it holds —
/// the model stores exactly one thing, and it is the person's own choice.
private struct SilentHealthStore: HealthStore {
    func requestReadAuthorization() async {}

    func requestWriteAuthorization() async {}

    func restingHeartRate(from _: Date, to _: Date) async -> [DailyQuantity] {
        []
    }

    func heartRateVariability(from _: Date, to _: Date) async -> [DailyQuantity] {
        []
    }

    func writeMindfulSession(from _: Date, to _: Date) async {}
}

/// Deleting an account, over the real stores rather than spies of them.
///
/// The server half of a deletion is one `DELETE` and the schema does the rest.
/// This half has no cascade: the practice is spread across two files, half a
/// dozen `UserDefaults` keys and the in-memory copies each of those is read into
/// at launch, and every one of them has to be emptied by name. A spy would prove
/// only that `AccountModel` called something.
///
/// Driven through the same seams `AccountModelTests` uses — a minting identity
/// store over storage that never touches a Keychain, and a `UserDefaults` suite
/// nobody else shares — so this runs on the host with no simulator.
@MainActor
@Suite("Deleting an account")
struct AccountDeletionTests {
    /// Everything a deletion has to reach, wired the way the composition root
    /// wires it.
    private struct Install {
        let identity: KeychainUserIdentityStore
        let accounts: ErasingAccounts
        let sessions: FileSessionStore
        let scores: FileBoltScoreStore
        let queue: SessionSyncQueue
        let profiles: ProfileStore
        let plus: SubscriptionStore
        let entitlements: RecordingEntitlements
        let health: HealthContextModel
        let outbox: WatchHandoffOutbox
        let defaults: UserDefaults
        let account: AccountModel
        let told: OSAllocatedUnfairLock<Int>
    }

    private func install(accounts: ErasingAccounts = ErasingAccounts()) throws -> Install {
        let directory = URL.temporaryDirectory.appending(path: "ond-deletion-\(UUID().uuidString)")
        let defaults = try #require(
            UserDefaults(suiteName: "deletion-tests.\(UUID().uuidString)")
        )

        let identity = KeychainUserIdentityStore(storage: FakeStorage(holding: UUID()))
        let sessions = FileSessionStore(directory: directory)
        let scores = FileBoltScoreStore(directory: directory)
        let queue = SessionSyncQueue(
            sessions: sessions,
            scores: scores,
            journeys: ServerSpy(),
            tombstones: sessions,
            ledger: SyncLedger(defaults: defaults)
        )
        let profiles = ProfileStore(profiles: SettledProfiles(), defaults: defaults)
        let entitlements = RecordingEntitlements()
        let plus = SubscriptionStore(
            front: SubscribedStoreFront(),
            entitlements: entitlements,
            defaults: defaults
        )
        let health = HealthContextModel(store: SilentHealthStore(), defaults: defaults)
        let outbox = WatchHandoffOutbox(identity: identity, scores: scores, defaults: defaults)
        let told = OSAllocatedUnfairLock(initialState: 0)

        return Install(
            identity: identity,
            accounts: accounts,
            sessions: sessions,
            scores: scores,
            queue: queue,
            profiles: profiles,
            plus: plus,
            entitlements: entitlements,
            health: health,
            outbox: outbox,
            defaults: defaults,
            account: AccountModel(
                identity: identity,
                accounts: accounts,
                stores: [sessions, scores, queue, profiles, plus, health, outbox],
                defaults: defaults
            ) {
                told.withLock { $0 += 1 }
            },
            told: told
        )
    }

    /// A person who has used the app: onboarded, breathed twice, deleted one of
    /// those sessions, taken a controlled-pause test, opted the coach into their
    /// heart trends, and synced.
    private func givenAPractice(on install: Install) async {
        install.profiles.complete(
            with: Profile(
                goals: [],
                experienceLevel: .new,
                reminderIntensity: .never,
                intentNote: "to sleep"
            )
        )
        install.health.coachReadsHeartTrends = true

        let kept = SessionRecord(
            techniqueSlug: "box-breathing",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: .milliseconds(120_000),
            cyclesCompleted: 8,
            breathCount: 8,
            completed: true
        )
        let deleted = SessionRecord(
            techniqueSlug: "physiological-sigh",
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            duration: .milliseconds(60000),
            cyclesCompleted: 4,
            breathCount: 4,
            completed: true
        )
        await install.sessions.record(kept)
        await install.sessions.record(deleted)
        await install.scores.record(BoltScore(seconds: 41))

        // Fills the ledger, which is the one store that only exists once
        // something has actually been sent.
        await install.queue.sync()
        await install.sessions.remove(deleted.id)
    }

    /// The whole of it, asserted store by store rather than through a spy.
    ///
    /// The subscription is the assertion that is *not* about erasure, and it is
    /// the one the confirmation copy promises: deleting an account cannot cancel
    /// an App Store subscription, so the tier has to come back from `StoreKit`
    /// rather than be left cleared — otherwise the app has appeared to cancel
    /// something it has no power over.
    @Test("Everything this device held is emptied, under an identity nobody has seen")
    func erasesEveryLocalStore() async throws {
        let install = try install()
        let before = install.identity.userId()
        await givenAPractice(on: install)

        await install.account.deleteAccount()

        #expect(install.accounts.deletions == 1)

        let sessions = await install.sessions.recordedSessions()
        let tombstones = await install.sessions.tombstonedSessions()
        let scores = await install.scores.recordedScores()
        #expect(sessions.isEmpty)
        #expect(tombstones.isEmpty, "a deletion in flight is a subset of this one")
        #expect(scores.isEmpty)

        #expect(install.profiles.profile == .unanswered)
        #expect(install.profiles.hasCompletedOnboarding == false)
        #expect(install.health.coachReadsHeartTrends == false)
        #expect(
            install.defaults.stringArray(forKey: "journey.acknowledgedSessions") == nil,
            "the ledger answered for an identity that no longer exists"
        )
        #expect(
            install.defaults.object(forKey: "profile.answers") == nil,
            "an empty profile encoded into the defaults is still a record of somebody"
        )

        #expect(install.identity.userId() != nil)
        #expect(install.identity.userId() != before, "one request on the old id resurrects it")
        #expect(install.account.state == .localOnly)
        #expect(install.account.failure == nil)
        #expect(install.told.withLock { $0 } == 1, "the watch and the journey both hold a copy")

        #expect(
            install.plus.tier == .coach,
            "the subscription is Apple's to cancel, and the confirmation says so"
        )
        #expect(
            install.entitlements.submissions == 1,
            "the erased row took the App Store binding with it, so it is claimed again"
        )
    }

    /// The order that makes a failed deletion survivable. Nothing local is
    /// touched until the server has actually erased the row, so somebody on a
    /// train is left with an app they can ask again from — rather than an empty
    /// one and a server that still holds everything.
    @Test("A deletion the server refused leaves the device exactly as it was")
    func keepsEverythingWhenTheServerCannotBeReached() async throws {
        let install = try install(
            accounts: ErasingAccounts(failingWith: AccountRepositoryError.transport("no route"))
        )
        let before = install.identity.userId()
        await givenAPractice(on: install)

        await install.account.deleteAccount()

        let sessions = await install.sessions.recordedSessions()
        #expect(sessions.count == 1)
        #expect(install.profiles.hasCompletedOnboarding)
        #expect(install.identity.userId() == before)
        #expect(install.account.failure != nil)
        #expect(install.told.withLock { $0 } == 0)
    }

    /// The wrist's half, from the phone's side: the context the watch is next
    /// handed has to name the fresh identity, carry no personal best, and say
    /// that what it replaces was deleted rather than merely renamed.
    ///
    /// All three come out of the ordering in `deleteAccount` — mint, then empty,
    /// then tell — and any other order produces a context that looks ordinary.
    @Test("The next context tells the watch there is nothing left to hold")
    func handsTheWatchAnErasure() async throws {
        let install = try install()
        await givenAPractice(on: install)

        await install.account.deleteAccount()

        var handed: WatchHandoff?
        await install.outbox.handOver { handed = $0 }
        let handoff = try #require(handed)

        #expect(handoff.userId == install.identity.userId())
        #expect(handoff.boltBestSeconds == nil)
        #expect(handoff.erasesPriorHistory)
    }
}
