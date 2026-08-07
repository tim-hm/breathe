import BreatheKit
import Foundation
import os
import WatchConnectivity

/// The phone's side of the pairing: it tells the watch who this person is.
///
/// One direction only, and deliberately. The watch talks to the backend itself —
/// it holds its own catalogue cache and drains its own sessions — so the phone
/// owes it exactly two things it cannot work out alone: the anonymous identity,
/// which the watch must never mint for itself, and the best controlled pause,
/// which is measured on a screen the wrist does not have.
///
/// `applicationContext` rather than a message: this is state, not an event. The
/// system keeps the latest one and delivers it whenever the watch next runs, so
/// a phone sending into a watch that is off charge loses nothing.
@MainActor
final class WatchLink: NSObject {
    private static let logger = Logger(category: "watch-link")

    private let identity: any UserIdentityStore
    private let scores: any BoltScoreRecording

    /// The last context handed over, so an unchanged one is not handed over
    /// again. Every foreground calls `push()` and almost none of them carry
    /// news; `updateApplicationContext` wakes the watch to deliver whatever it
    /// is given, so sending the same two values repeatedly is radio time spent
    /// on nothing.
    private var sent: WatchHandoff?

    init(identity: any UserIdentityStore, scores: any BoltScoreRecording) {
        self.identity = identity
        self.scores = scores
    }

    /// Activates the session if it needs it, and sends the current context.
    ///
    /// Safe and cheap to call on every foreground, which is how the phone keeps
    /// a mirrored personal best from going stale: `updateApplicationContext`
    /// overwrites rather than queues, and an unpaired phone drops out at the
    /// first guard.
    func push() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        if session.delegate == nil {
            session.delegate = self
        }

        guard session.activationState == .activated else {
            // The activation callback sends the first context. Activating twice
            // is harmless, and doing it here is what covers the launch where
            // nothing else would.
            session.activate()
            return
        }

        Task { await send() }
    }

    /// Reads the current identity and best pause and hands them over.
    ///
    /// Silent when there is no identity yet: minting is lazy on first use, and a
    /// context with no id is one the watch would refuse anyway.
    private func send() async {
        guard let userId = identity.userId() else { return }
        let handoff = await WatchHandoff(userId: userId, boltBestSeconds: scores.personalBest())
        guard handoff != sent else { return }

        let session = WCSession.default
        // The pairing can go away between the guard above and here — a person
        // unpairing their watch mid-launch — so this is checked at the point of
        // use rather than trusted from earlier.
        guard session.activationState == .activated, session.isPaired else { return }

        do {
            try session.updateApplicationContext(handoff.dictionary)
            // Recorded only on success, so a failed send is retried by the next
            // foreground rather than remembered as delivered.
            sent = handoff
        } catch {
            // Nothing to retry and nothing to tell anyone: the next foreground
            // sends the same context again, and until then the watch works
            // anonymously by design.
            Self.logger
                .notice("watch handoff deferred: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The delegate methods arrive off the main actor, so each one hops rather than
/// doing work where it lands. `WCSession` itself is not `Sendable` and is never
/// captured across the hop — the shared instance is read again on the far side.
extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error _: (any Error)?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor in await self.send() }
    }

    nonisolated func sessionDidBecomeInactive(_: WCSession) {}

    /// Somebody switched watches. The documented response is to reactivate, so
    /// the new one receives the context the old one had.
    nonisolated func sessionDidDeactivate(_: WCSession) {
        Task { @MainActor in WCSession.default.activate() }
    }
}
