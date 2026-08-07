import BreatheKit
import Foundation
import os
import SwiftUI
import WatchConnectivity

/// The watch's side of the pairing: it listens, and never asks.
///
/// Everything the phone sends is state the wrist cannot derive — the anonymous
/// identity, which this app must never mint for itself, and the best controlled
/// pause, which is measured on a screen the watch does not have. Nothing here
/// blocks: a watch that has never seen its phone still shows the catalogue,
/// still records sessions locally, and simply carries an unacknowledged sync
/// queue until an identity arrives.
@MainActor
@Observable
final class PhoneLink: NSObject {
    /// `watch-link`, the same category the phone's `WatchLink` files under:
    /// correlating a handoff that never arrived means reading one channel, not
    /// guessing at two names for the two ends of it.
    private static let logger = Logger(category: "watch-link")

    /// The identity now in hand, or nil while this watch is still anonymous.
    /// Observed rather than merely stored so the composition root can start a
    /// sync the moment one lands.
    private(set) var userId: UUID?

    /// The phone's best controlled pause, or nil until a context has been read.
    ///
    /// Deliberately not persisted alongside the identity. The system already
    /// keeps the last `applicationContext`, and `activate()` below replays it on
    /// every launch, so a copy in `UserDefaults` would be a second source of
    /// truth free to go stale against the first. What that costs is the fraction
    /// of a second between launch and activation with no number in hand — and
    /// the screen that shows it is two taps away.
    private(set) var boltBestSeconds: Int?

    private let identity: ProvisionedUserIdentityStore

    init(identity: ProvisionedUserIdentityStore) {
        self.identity = identity
        userId = identity.userId()
        super.init()
    }

    /// Starts listening. Called once, from the app's root task.
    ///
    /// Activation also makes `receivedApplicationContext` readable, which is
    /// what covers the ordinary case: the phone sent its context while this app
    /// was not running, so there is nothing to be delivered — only something
    /// already waiting.
    func activate() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Adopts a context, from wherever it arrived.
    ///
    /// Everything here is idempotent: the phone re-sends on every foreground, so
    /// the overwhelmingly common call is one that changes nothing.
    private func adopt(_ handoff: WatchHandoff) {
        if identity.provision(handoff.userId) {
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

/// The delegate methods arrive off the main actor with an untyped dictionary.
/// Each one decodes on the queue it lands on — `WatchHandoff` is `Sendable`,
/// where the `[String: Any]` it came from is not — and hops with the result.
extension PhoneLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error _: (any Error)?
    ) {
        guard activationState == .activated,
              let handoff = WatchHandoff(dictionary: session.receivedApplicationContext)
        else {
            return
        }

        Task { @MainActor in self.adopt(handoff) }
    }

    nonisolated func session(
        _: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let handoff = WatchHandoff(dictionary: applicationContext) else { return }
        Task { @MainActor in self.adopt(handoff) }
    }
}
