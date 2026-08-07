import BreatheKit
import Foundation
import WatchConnectivity

/// The watch's side of the pairing: it listens, and never asks.
///
/// Everything the phone sends is state the wrist cannot derive — the anonymous
/// identity, which this app must never mint for itself, and the best controlled
/// pause, which is measured on a screen the watch does not have. Nothing here
/// blocks: a watch that has never seen its phone still shows the catalogue,
/// still records sessions locally, and simply carries an unacknowledged sync
/// queue until an identity arrives.
///
/// The radio and nothing else. What a context means — provisioning the identity,
/// keeping a mirrored best that a later context does not carry — is
/// `BreatheKit`'s `WatchHandoffInbox`, which is also what the rest of the app
/// observes.
@MainActor
final class PhoneLink: NSObject {
    private let inbox: WatchHandoffInbox

    init(inbox: WatchHandoffInbox) {
        self.inbox = inbox
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

        Task { @MainActor in self.inbox.adopt(handoff) }
    }

    nonisolated func session(
        _: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let handoff = WatchHandoff(dictionary: applicationContext) else { return }
        Task { @MainActor in self.inbox.adopt(handoff) }
    }
}
