import Foundation
import os

/// Drains the local stores into the server, and never the other way round for
/// anything the screen needs.
///
/// The app is offline-first: the file on this device is the source of truth, and
/// this queue is how the server finds out about it. Nothing here blocks a view,
/// nothing here throws at a caller, and a failed run leaves the ledger untouched
/// so the next one picks up exactly what was missed.
///
/// The ledger is a set of acknowledged ids rather than a high-water timestamp.
/// A timestamp assumes sessions arrive in order, which they do not — a watch
/// session recorded on Tuesday can reach the file after Wednesday's — and would
/// silently skip anything that landed behind the mark.
public actor SessionSyncQueue {
    private static let logger = Logger(category: "journey-sync")

    private static let acknowledgedSessionsKey = "journey.acknowledgedSessions"
    private static let acknowledgedScoresKey = "journey.acknowledgedBoltScores"

    /// Matches the server's own cap on one `RecordSessions` call. A backlog
    /// larger than this drains over several runs rather than being refused.
    private static let maxBatch = 200

    /// How many restore pages one run will walk before giving up.
    ///
    /// At the page size the repository asks for this is more history than a
    /// lifetime of daily practice, so reaching it means the server is handing
    /// back a token it should not — and a loop that trusted the token alone
    /// would run forever on a foreground. Logged at `error` because it can only
    /// be a bug on one side or the other.
    private static let maxRestorePages = 40

    private let sessions: any SessionRecording
    private let scores: any BoltScoreRecording
    private let journeys: any JourneySyncing
    private let tombstones: (any TombstoneStoring)?
    private let ledger: SyncLedger

    /// - Parameter tombstones: where deletions wait for the server. Optional
    ///   because `SessionRecording` cannot express it — a caller that has only
    ///   the recording seam still syncs, it just never drains deletions, which
    ///   is the behaviour that existed before `DeleteSessions` did.
    public init(
        sessions: any SessionRecording,
        scores: any BoltScoreRecording,
        journeys: any JourneySyncing,
        tombstones: (any TombstoneStoring)? = nil,
        ledger: SyncLedger = SyncLedger()
    ) {
        self.sessions = sessions
        self.scores = scores
        self.journeys = journeys
        self.tombstones = tombstones
        self.ledger = ledger
    }

    /// Sends whatever the server has not acknowledged, then takes back anything
    /// it holds that this device has lost.
    ///
    /// Safe to call on every foreground and after every session: it returns
    /// almost immediately when there is nothing outstanding, and being an actor
    /// is what stops two of those overlapping into a double send.
    ///
    /// - Returns: whether the local stores changed, which only a restore can do.
    ///   Sending changes nothing on this device, so a caller that re-reads on
    ///   every sync would re-read for nothing on all but the first run after a
    ///   reinstall.
    @discardableResult
    public func sync() async -> Bool {
        // Deletions go first so the restore at the end reads a server that has
        // already forgotten them. Any other order would have the same run pull
        // back sessions this one was about to delete, and leave the tombstones
        // doing the filtering for another cycle.
        await sendDeletions()
        await sendSessions()
        await sendScores()
        return await restore()
    }

    /// Tells the server about sessions deleted here, and forgets the tombstone
    /// only once it has said so.
    ///
    /// The order is the whole point: a tombstone dropped before the server
    /// confirmed would let the next restore hand the session back, which is the
    /// resurrection this exists to prevent. A failed call leaves the file
    /// untouched and the next run tries again.
    private func sendDeletions() async {
        guard let tombstones else { return }

        let pending = await tombstones.tombstonedSessions()
        guard !pending.isEmpty else { return }

        let batch = Array(pending.prefix(Self.maxBatch))
        do {
            try await journeys.delete(batch)
            await tombstones.forgetTombstones(batch)
        } catch {
            Self.logger
                .notice(
                    "session deletion deferred: \(error.localizedDescription, privacy: .public)"
                )
        }
    }

    private func sendSessions() async {
        let recorded = await sessions.recordedSessions()
        var acknowledged = ledger.acknowledged(
            Self.acknowledgedSessionsKey,
            keeping: recorded.map(\.id)
        )
        // Written on every run, not only a successful send: the read above has
        // already dropped ids whose sessions are gone, and that pruning is what
        // stops the ledger growing for the life of the install.
        defer { ledger.store(acknowledged, at: Self.acknowledgedSessionsKey) }

        let pending = recorded.filter { !acknowledged.contains($0.id) }
        guard !pending.isEmpty else { return }

        let batch = Array(pending.prefix(Self.maxBatch))
        do {
            try await journeys.record(batch)
            acknowledged.formUnion(batch.map(\.id))
        } catch {
            // Not surfaced: a session that syncs a day late costs the person
            // nothing, and there is no action they could take from a view.
            Self.logger
                .notice("session sync deferred: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendScores() async {
        let recorded = await scores.recordedScores()
        var acknowledged = ledger.acknowledged(
            Self.acknowledgedScoresKey,
            keeping: recorded.map(\.id)
        )
        defer { ledger.store(acknowledged, at: Self.acknowledgedScoresKey) }

        let pending = recorded.filter { !acknowledged.contains($0.id) }
        guard !pending.isEmpty else { return }

        // One call each rather than a batch: the RPC takes a single score, and
        // somebody accumulates these one deliberate test at a time.
        for score in pending.prefix(Self.maxBatch) {
            do {
                try await journeys.record(score)
                acknowledged.insert(score.id)
            } catch {
                Self.logger
                    .notice("bolt sync deferred: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }

    /// Pulls back every session the server holds and this device does not.
    ///
    /// The Keychain identity survives a reinstall while the sessions file does
    /// not, so this is what stops somebody's streak vanishing because they
    /// changed phones. Anything restored is acknowledged on arrival — it came
    /// from the server, so sending it back would be pure noise.
    ///
    /// Pages until the server stops offering a token. A single call would return
    /// only the newest page, and the totals and streaks that come back alongside
    /// it would be right — which is what makes a truncated restore so hard to
    /// notice, and why this loop stops only on an exhausted history or a failed
    /// request.
    ///
    /// A failed page keeps whatever earlier ones brought back rather than
    /// discarding it: the merge is idempotent on session id and the next run
    /// starts again from the newest page, so a partial restore costs a repeat
    /// rather than a gap.
    private func restore() async -> Bool {
        var changed = false
        var pageToken: String?

        for _ in 0 ..< Self.maxRestorePages {
            do {
                let page = try await journeys.storedSessions(after: pageToken)
                if !page.sessions.isEmpty {
                    let merged = await sessions.merge(page.sessions)
                    changed = changed || merged
                    // Union rather than a fresh prune: `sendSessions` has already
                    // pruned this key on the way past, and re-deriving the present
                    // ids would mean reading the whole session file again to learn
                    // what was just written to it.
                    ledger.acknowledge(page.sessions.map(\.id), at: Self.acknowledgedSessionsKey)
                }

                guard let next = page.nextPageToken else { return changed }
                pageToken = next
            } catch {
                Self.logger
                    .notice(
                        "journey restore deferred: \(error.localizedDescription, privacy: .public)"
                    )
                return changed
            }
        }

        Self.logger.error("journey restore stopped at the page ceiling")
        return changed
    }
}

/// Which ids the server has confirmed, kept in `UserDefaults`.
///
/// A wrapper rather than a bare `UserDefaults` on the queue for one reason:
/// `UserDefaults` is documented as thread-safe and is not annotated `Sendable`,
/// so it cannot cross into an actor without the compiler objecting. Confining
/// the `@unchecked` to this one small type is better than spreading an
/// unexplained exception through the queue.
public struct SyncLedger: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The acknowledged set, pruned to ids that still exist locally.
    ///
    /// Without the pruning the ledger only ever grows, and somebody who has
    /// breathed daily for three years would carry a thousand dead ids into every
    /// launch.
    func acknowledged(_ key: String, keeping present: [UUID]) -> Set<UUID> {
        let stored = defaults.stringArray(forKey: key) ?? []
        return Set(stored.compactMap(UUID.init(uuidString:))).intersection(present)
    }

    /// Writes only on a genuine change. A sync with nothing outstanding is the
    /// common case — every foreground, every finished session — and it would
    /// otherwise rewrite two identical arrays each time.
    func store(_ ids: Set<UUID>, at key: String) {
        let encoded = ids.map(\.uuidString).sorted()
        guard defaults.stringArray(forKey: key) != encoded else { return }

        defaults.set(encoded, forKey: key)
    }

    /// Adds ids without pruning — for sessions that arrived from the server and
    /// are therefore acknowledged the moment they land.
    func acknowledge(_ ids: [UUID], at key: String) {
        let stored = defaults.stringArray(forKey: key) ?? []
        store(Set(stored.compactMap(UUID.init(uuidString:))).union(ids), at: key)
    }
}
