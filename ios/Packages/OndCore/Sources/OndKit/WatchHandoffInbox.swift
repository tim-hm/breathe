import Foundation
import os

/// The watch's half of the pairing, minus the radio: everything the phone has
/// told this wrist about the person wearing it.
///
/// Here rather than in the watch target for the same reason the outbox is: what
/// `adopt` does is stateful, replayed on every activation, and silent when it
/// goes wrong — a watch left anonymous, or a mirrored personal best blanked by a
/// context that never carried one. The watch target has no test bundle, so
/// `PhoneLink` keeps the `WCSession` delegate callbacks and hands everything
/// they decode to this. The loudest of those failures is the last one it can
/// make: a context that says the person has deleted their account, ignored,
/// leaves the wrist syncing their erased practice back under a fresh identity.
@MainActor
@Observable
public final class WatchHandoffInbox {
    /// `watch-link`, the same category the phone's `WatchLink` files under:
    /// correlating a handoff that never arrived means reading one channel, not
    /// guessing at two names for the two ends of it.
    private static let logger = Logger(category: "watch-link")

    /// The identity now in hand, or nil while this watch is still anonymous.
    /// Observed rather than merely stored so the composition root can start a
    /// sync the moment one lands.
    public private(set) var userId: UUID?

    /// The phone's best controlled pause, or nil until a context has been read.
    ///
    /// Deliberately not persisted alongside the identity. The system already
    /// keeps the last `applicationContext` and replays it on every activation,
    /// so a copy in `UserDefaults` would be a second source of truth free to go
    /// stale against the first. What that costs is the fraction of a second
    /// between launch and activation with no number in hand — and the screen
    /// that shows it is two taps away.
    public private(set) var boltBestSeconds: Int?

    private let identity: ProvisionedUserIdentityStore
    private let stores: [any PersonalStore]

    /// - Parameter stores: what this wrist holds of its own — the sessions
    ///   breathed on it and the ledger of what has been sent — for the one
    ///   context that says the person they belonged to has been erased.
    public init(identity: ProvisionedUserIdentityStore, stores: [any PersonalStore]) {
        self.identity = identity
        self.stores = stores
        userId = identity.userId()
    }

    /// Adopts a context, from wherever it arrived.
    ///
    /// Everything here is idempotent: the phone re-sends on every foreground, so
    /// the overwhelmingly common call is one that changes nothing.
    public func adopt(_ handoff: WatchHandoff) async {
        let changed = identity.adopt(handoff.userId)
        if changed {
            Self.logger.notice("adopted the phone's identity")
        }
        userId = identity.userId()

        // Only overwritten by a context that carries one: a phone whose owner
        // has not taken the test yet should not blank a number this watch was
        // given before. An erasure is the exception, and takes the `nil` with
        // everything else below.
        if let best = handoff.boltBestSeconds {
            boltBestSeconds = best
        }

        guard changed, handoff.erasesPriorHistory else { return }
        await erasePriorHistory()
    }

    /// Empties this wrist of the person the phone has just erased.
    ///
    /// Guarded on the identity having *actually changed*, which is what makes it
    /// safe to act on a flag the system will replay forever: the id a deletion
    /// minted becomes new to this watch exactly once, and every later delivery
    /// of the same context finds it already adopted and does nothing. Without
    /// that guard this would wipe the wrist's own practice on every activation
    /// until the person next signed in.
    ///
    /// The sessions are the reason this exists rather than the identity. A watch
    /// that only swapped ids would take its backlog — recorded under somebody
    /// who asked to be forgotten — and sync it straight into the fresh account
    /// they were given, which is a deletion that hands the history back.
    private func erasePriorHistory() async {
        for store in stores {
            await store.erase()
        }

        boltBestSeconds = nil
        Self.logger.notice("erased what this wrist held for a deleted account")
    }
}
