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
/// they decode to this.
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

    public init(identity: ProvisionedUserIdentityStore) {
        self.identity = identity
        userId = identity.userId()
    }

    /// Adopts a context, from wherever it arrived.
    ///
    /// Everything here is idempotent: the phone re-sends on every foreground, so
    /// the overwhelmingly common call is one that changes nothing.
    public func adopt(_ handoff: WatchHandoff) {
        if identity.adopt(handoff.userId) {
            Self.logger.notice("adopted the phone's identity")
        }
        userId = identity.userId()

        // Only overwritten by a context that carries one: a phone whose owner
        // has not taken the test yet should not blank a number this watch was
        // given before.
        if let best = handoff.boltBestSeconds {
            boltBestSeconds = best
        }
    }
}
