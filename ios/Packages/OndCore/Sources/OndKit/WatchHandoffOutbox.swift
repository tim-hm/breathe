import Foundation

/// The phone's half of the pairing, minus the radio: what the watch is owed, and
/// what it has already been told.
///
/// Here rather than in the app target because the deduplication below is the
/// point of the phone's `WatchLink` and its failure mode is "nothing happened" —
/// either a context that stops being sent when it should not, or one re-sent on
/// every foreground, waking a watch to deliver news it already has. Neither
/// shows up on a screen, and the app target has no test bundle. `WatchLink`
/// keeps the `WCSession` calls and nothing else.
@MainActor
public final class WatchHandoffOutbox {
    private let identity: any UserIdentityStore
    private let scores: any BoltScoreRecording

    /// The last context confirmed delivered, so an unchanged one is not handed
    /// over again. Every foreground asks, and almost none of them carry news.
    private var sent: WatchHandoff?

    public init(identity: any UserIdentityStore, scores: any BoltScoreRecording) {
        self.identity = identity
        self.scores = scores
    }

    /// Offers whatever is outstanding to `send`, and remembers it only if that
    /// returned without throwing — so a hand-over that failed is retried by the
    /// next foreground rather than recorded as delivered.
    ///
    /// `send` takes the radio and nothing else. Passing it in rather than
    /// returning the context and trusting the caller to report back is what puts
    /// the whole rule in one tested place: there is no call sequence a caller
    /// can get wrong.
    ///
    /// `send` is not called at all in two cases that look alike from outside and
    /// differ underneath: no identity has been minted yet — minting is lazy on
    /// first use, and a context with no id is one the watch would refuse anyway —
    /// or the watch already holds exactly this.
    public func handOver(_ send: (WatchHandoff) throws -> Void) async rethrows {
        guard let userId = identity.userId() else { return }

        let handoff = await WatchHandoff(userId: userId, boltBestSeconds: scores.personalBest())
        guard handoff != sent else { return }

        try send(handoff)
        sent = handoff
    }
}
