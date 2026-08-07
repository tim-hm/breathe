import Foundation
import OndKit
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
///
/// Everything that is not `WCSession` lives in `OndKit`'s
/// `WatchHandoffOutbox`, which decides what is worth sending and remembers what
/// got through — this type is the radio around it.
@MainActor
final class WatchLink: NSObject {
    private static let logger = Logger(category: "watch-link")

    private let outbox: WatchHandoffOutbox

    init(outbox: WatchHandoffOutbox) {
        self.outbox = outbox
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

    /// Hands over whatever the outbox says is outstanding.
    ///
    /// A pairing that goes away between the guard and the call — somebody
    /// unpairing their watch mid-launch — throws, which the outbox reads as
    /// undelivered. The guard is there to skip a read of the score file that
    /// would go nowhere, not to make the send safe.
    private func send() async {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else { return }

        do {
            try await outbox.handOver { handoff in
                try session.updateApplicationContext(handoff.dictionary)
            }
        } catch {
            // Nothing to retry and nothing to tell anyone: the context stays
            // outstanding, the next foreground offers it again, and until then
            // the watch works anonymously by design.
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
