import Foundation

/// The phone's half of the pairing, minus the radio: what the watch is owed,
/// what it has already been told, and the one thing it is owed across a
/// relaunch.
///
/// Here rather than in the app target because the deduplication below is the
/// point of the phone's `WatchLink` and its failure mode is "nothing happened" —
/// either a context that stops being sent when it should not, or one re-sent on
/// every foreground, waking a watch to deliver news it already has. Neither
/// shows up on a screen, and the app target has no test bundle. `WatchLink`
/// keeps the `WCSession` calls and nothing else.
@MainActor
public final class WatchHandoffOutbox: PersonalStore {
    /// The identity a deletion minted, so the context that carries it can say
    /// what it replaced.
    ///
    /// On disk rather than in memory, because the wrist may be off, out of range
    /// or unpaired for days after somebody deletes their account, and the phone
    /// is very likely to be relaunched in between. A flag that lived for the
    /// process would leave the watch holding an erased person's practice with
    /// nothing left anywhere to tell it otherwise.
    private static let erasedKey = "watch.identityAfterDeletion"

    private let identity: any UserIdentityStore
    private let scores: any BoltScoreRecording
    private let defaults: UserDefaults

    /// The last context confirmed delivered, so an unchanged one is not handed
    /// over again. Every foreground asks, and almost none of them carry news.
    private var sent: WatchHandoff?

    public init(
        identity: any UserIdentityStore,
        scores: any BoltScoreRecording,
        defaults: UserDefaults = .standard
    ) {
        self.identity = identity
        self.scores = scores
        self.defaults = defaults
    }

    /// Forgets what the watch was told, and records *why* it is about to be told
    /// something different.
    ///
    /// The outbox holds no practice of its own. What it holds is a claim about
    /// another device, and after a deletion that claim is both stale and
    /// dangerous — the wrist has the erased person's identity, their best pause,
    /// and whatever they breathed on it that has not gone up yet.
    ///
    /// Stored as the id itself rather than as a flag, which is what makes it
    /// self-expiring: a later sign-in or sign-out mints another id, the stored
    /// one stops matching, and the contexts that follow are ordinary again with
    /// nothing to remember to clear. Reading it from the identity store rather
    /// than being handed it is what keeps the ordering honest — `AccountModel`
    /// mints before it erases, so the replacement is already in place here.
    public func erase() async {
        sent = nil

        guard let userId = identity.userId() else { return }
        defaults.set(userId.uuidString, forKey: Self.erasedKey)
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

        let handoff = await WatchHandoff(
            userId: userId,
            boltBestSeconds: scores.personalBest(),
            erasesPriorHistory: defaults.string(forKey: Self.erasedKey) == userId.uuidString
        )
        guard handoff != sent else { return }

        try send(handoff)
        sent = handoff
    }
}
