import Foundation
@testable import OndKit
import Testing

/// The watch's half of the handoff: what the wrist does with a context once it
/// has one.
///
/// Worth pinning because the phone re-sends on every foreground and the system
/// replays the last context on every activation, so `adopt` is called far more
/// often than anything changes — and each of the rules below is one that only
/// shows itself on the replay. A watch left anonymous, or a mirrored best
/// blanked by a context that never carried one, looks from the outside like a
/// screen that simply has no number on it.
@MainActor
@Suite("Watch handoff inbox")
struct WatchHandoffInboxTests {
    @Test("A watch that has never met its phone is anonymous, with no best")
    func startsAnonymous() {
        let inbox =
            WatchHandoffInbox(
                identity: ProvisionedUserIdentityStore(storage: FakeStorage()),
                stores: []
            )

        #expect(inbox.userId == nil)
        #expect(inbox.boltBestSeconds == nil)
    }

    /// The launch that covers most launches: the identity is already stored, and
    /// the screens are drawn before `WCSession` has activated. Reading it in the
    /// initialiser is what keeps that first frame attributable.
    @Test("A stored identity is in hand before any context arrives")
    func readsTheStoredIdentityAtOnce() {
        let id = UUID()
        let inbox = WatchHandoffInbox(
            identity: ProvisionedUserIdentityStore(storage: FakeStorage(holding: id)),
            stores: []
        )

        #expect(inbox.userId == id)
    }

    @Test("A context hands over the identity and the phone's best pause")
    func adoptsAContext() async {
        let inbox =
            WatchHandoffInbox(
                identity: ProvisionedUserIdentityStore(storage: FakeStorage()),
                stores: []
            )
        let id = UUID()

        await inbox.adopt(WatchHandoff(userId: id, boltBestSeconds: 38))

        #expect(inbox.userId == id)
        #expect(inbox.boltBestSeconds == 38)
    }

    /// The system replays the last `applicationContext` on every activation and
    /// the phone re-sends on every foreground, so the overwhelmingly common call
    /// is one that must change nothing.
    @Test("Re-adopting the same context changes nothing")
    func isIdempotent() async {
        let inbox =
            WatchHandoffInbox(
                identity: ProvisionedUserIdentityStore(storage: FakeStorage()),
                stores: []
            )
        let handoff = WatchHandoff(userId: UUID(), boltBestSeconds: 38)

        await inbox.adopt(handoff)
        await inbox.adopt(handoff)

        #expect(inbox.userId == handoff.userId)
        #expect(inbox.boltBestSeconds == 38)
    }

    /// The rule that only bites on a replay: a phone whose owner has not taken
    /// the test yet sends a context with no score in it, and that must not blank
    /// a number this watch was already given.
    @Test("A context with no best does not blank the one already held")
    func keepsABestASilentContextOmits() async {
        let inbox =
            WatchHandoffInbox(
                identity: ProvisionedUserIdentityStore(storage: FakeStorage()),
                stores: []
            )
        let id = UUID()

        await inbox.adopt(WatchHandoff(userId: id, boltBestSeconds: 38))
        await inbox.adopt(WatchHandoff(userId: id))

        #expect(inbox.boltBestSeconds == 38)
    }

    /// Somebody who reinstalled the phone app arrives with a new id. The phone is
    /// the authority on who this person is, so the wrist follows it rather than
    /// syncing to an identity nothing else writes to.
    @Test("A new identity from the phone replaces the old one")
    func followsThePhoneToANewIdentity() async {
        let storage = FakeStorage(holding: UUID())
        let inbox = WatchHandoffInbox(
            identity: ProvisionedUserIdentityStore(storage: storage),
            stores: []
        )
        let replacement = UUID()

        await inbox.adopt(WatchHandoff(userId: replacement))

        #expect(inbox.userId == replacement)
        #expect(storage.read() == replacement, "and it survives the next launch")
    }

    /// The deletion, from the wrist's side. Without this the watch keeps the
    /// erased person's sessions and syncs them straight back up under the fresh
    /// identity it has just been handed — a deletion that returns the history it
    /// deleted.
    @Test("A context that replaces a deleted identity empties the wrist")
    func erasesWhatADeletedAccountLeftBehind() async {
        let store = CountingStore()
        let inbox = WatchHandoffInbox(
            identity: ProvisionedUserIdentityStore(storage: FakeStorage(holding: UUID())),
            stores: [store]
        )

        await inbox.adopt(WatchHandoff(userId: UUID(), boltBestSeconds: 41))
        await inbox.adopt(WatchHandoff(userId: UUID(), erasesPriorHistory: true))

        #expect(store.erasures == 1)
        #expect(inbox.boltBestSeconds == nil, "the best pause belonged to the person erased")
    }

    /// The rule that makes a flag safe to carry in a context the system replays
    /// forever: the erasure is guarded on the identity having actually changed,
    /// so every later delivery of the same context finds it already adopted.
    ///
    /// Without the guard, a watch would wipe its own practice on every
    /// activation for as long as the phone carried that identity — which is
    /// until the person next signs in, and possibly never.
    @Test("A replayed erasure does not wipe what the wrist has done since")
    func erasesOnlyOnce() async {
        let store = CountingStore()
        let inbox = WatchHandoffInbox(
            identity: ProvisionedUserIdentityStore(storage: FakeStorage()),
            stores: [store]
        )
        let handoff = WatchHandoff(userId: UUID(), erasesPriorHistory: true)

        await inbox.adopt(handoff)
        await inbox.adopt(handoff)
        await inbox.adopt(handoff)

        #expect(store.erasures == 1)
    }

    /// The other half of the same rule. Signing in hands the wrist a different
    /// id and its unsent sessions go up under that one, which is where the
    /// person's practice now lives — so an ordinary swap must erase nothing.
    @Test("An identity swapped by a sign-in erases nothing")
    func keepsThePracticeThroughAnOrdinarySwap() async {
        let store = CountingStore()
        let inbox = WatchHandoffInbox(
            identity: ProvisionedUserIdentityStore(storage: FakeStorage(holding: UUID())),
            stores: [store]
        )

        await inbox.adopt(WatchHandoff(userId: UUID(), boltBestSeconds: 41))

        #expect(store.erasures == 0)
        #expect(inbox.boltBestSeconds == 41)
    }
}

/// A store that only records having been emptied. What each real one does with
/// its own files and keys is pinned beside those; what matters here is *whether*
/// the inbox asks, and exactly once.
@MainActor
private final class CountingStore: PersonalStore {
    private(set) var erasures = 0

    func erase() async {
        erasures += 1
    }
}
