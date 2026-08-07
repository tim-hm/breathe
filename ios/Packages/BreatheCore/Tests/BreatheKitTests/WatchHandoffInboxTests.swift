@testable import BreatheKit
import Foundation
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
            WatchHandoffInbox(identity: ProvisionedUserIdentityStore(storage: FakeStorage()))

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
            identity: ProvisionedUserIdentityStore(storage: FakeStorage(holding: id))
        )

        #expect(inbox.userId == id)
    }

    @Test("A context hands over the identity and the phone's best pause")
    func adoptsAContext() {
        let inbox =
            WatchHandoffInbox(identity: ProvisionedUserIdentityStore(storage: FakeStorage()))
        let id = UUID()

        inbox.adopt(WatchHandoff(userId: id, boltBestSeconds: 38))

        #expect(inbox.userId == id)
        #expect(inbox.boltBestSeconds == 38)
    }

    /// The system replays the last `applicationContext` on every activation and
    /// the phone re-sends on every foreground, so the overwhelmingly common call
    /// is one that must change nothing.
    @Test("Re-adopting the same context changes nothing")
    func isIdempotent() {
        let inbox =
            WatchHandoffInbox(identity: ProvisionedUserIdentityStore(storage: FakeStorage()))
        let handoff = WatchHandoff(userId: UUID(), boltBestSeconds: 38)

        inbox.adopt(handoff)
        inbox.adopt(handoff)

        #expect(inbox.userId == handoff.userId)
        #expect(inbox.boltBestSeconds == 38)
    }

    /// The rule that only bites on a replay: a phone whose owner has not taken
    /// the test yet sends a context with no score in it, and that must not blank
    /// a number this watch was already given.
    @Test("A context with no best does not blank the one already held")
    func keepsABestASilentContextOmits() {
        let inbox =
            WatchHandoffInbox(identity: ProvisionedUserIdentityStore(storage: FakeStorage()))
        let id = UUID()

        inbox.adopt(WatchHandoff(userId: id, boltBestSeconds: 38))
        inbox.adopt(WatchHandoff(userId: id))

        #expect(inbox.boltBestSeconds == 38)
    }

    /// Somebody who reinstalled the phone app arrives with a new id. The phone is
    /// the authority on who this person is, so the wrist follows it rather than
    /// syncing to an identity nothing else writes to.
    @Test("A new identity from the phone replaces the old one")
    func followsThePhoneToANewIdentity() {
        let storage = FakeStorage(holding: UUID())
        let inbox = WatchHandoffInbox(identity: ProvisionedUserIdentityStore(storage: storage))
        let replacement = UUID()

        inbox.adopt(WatchHandoff(userId: replacement))

        #expect(inbox.userId == replacement)
        #expect(storage.read() == replacement, "and it survives the next launch")
    }
}
