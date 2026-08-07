import Foundation
@testable import OndKit
import Testing

/// The bookkeeping that decides what crosses the network.
///
/// Worth testing because both ways of getting it wrong are invisible: a ledger
/// that forgets sends a person's whole history on every launch, and one that
/// remembers too eagerly loses the sessions a failed request never delivered.
@Suite("Session sync queue")
struct SessionSyncQueueTests {
    /// Records and tombstones together, the way `FileSessionStore` does — the
    /// two seams are separate protocols and one store answers both.
    private actor SessionSpy: SessionRecording, TombstoneStoring {
        private(set) var stored: [SessionRecord]
        private(set) var tombstoned: [SessionRecord.ID] = []

        init(_ stored: [SessionRecord] = []) {
            self.stored = stored
        }

        func record(_ session: SessionRecord) async {
            stored.append(session)
        }

        func remove(_ id: SessionRecord.ID) async {
            guard stored.contains(where: { $0.id == id }) else { return }
            stored.removeAll { $0.id == id }
            tombstoned.append(id)
        }

        func tombstonedSessions() async -> [SessionRecord.ID] {
            tombstoned
        }

        func forgetTombstones(_ ids: [SessionRecord.ID]) async {
            let forgotten = Set(ids)
            tombstoned.removeAll { forgotten.contains($0) }
        }

        func recordedSessions() async -> [SessionRecord] {
            stored
        }

        func merge(_ sessions: [SessionRecord]) async -> Bool {
            let known = Set(stored.map(\.id))
            let missing = sessions.filter { !known.contains($0.id) }
            stored.append(contentsOf: missing)
            return !missing.isEmpty
        }
    }

    private actor ScoreSpy: BoltScoreRecording {
        private(set) var stored: [BoltScore]

        init(_ stored: [BoltScore] = []) {
            self.stored = stored
        }

        func record(_ score: BoltScore) async {
            stored.append(score)
        }

        func recordedScores() async -> [BoltScore] {
            stored
        }
    }

    private struct Offline: Error {}

    private actor ServerSpy: JourneySyncing {
        /// Every session id this "server" has been sent, including repeats — so
        /// a test can tell "sent once" from "sent again".
        private(set) var received: [UUID] = []
        private(set) var receivedScores: [UUID] = []
        private(set) var deleted: [UUID] = []
        private var isReachable: Bool
        private var held: [SessionRecord]

        private let pageSize: Int

        init(isReachable: Bool = true, held: [SessionRecord] = [], pageSize: Int = 500) {
            self.isReachable = isReachable
            self.held = held
            self.pageSize = pageSize
        }

        func comeBackOnline() {
            isReachable = true
        }

        func record(_ sessions: [SessionRecord]) async throws {
            guard isReachable else { throw Offline() }
            received.append(contentsOf: sessions.map(\.id))
        }

        func delete(_ ids: [SessionRecord.ID]) async throws {
            guard isReachable else { throw Offline() }
            deleted.append(contentsOf: ids)
            held.removeAll { ids.contains($0.id) }
        }

        func record(_ score: BoltScore) async throws {
            guard isReachable else { throw Offline() }
            receivedScores.append(score.id)
        }

        /// Serves the held history one page at a time, keyed on the index the
        /// last page stopped at — the same contract the real server offers, so
        /// a queue that stopped after the first page fails here rather than
        /// only against Postgres.
        func storedSessions(after pageToken: String?) async throws -> StoredSessionPage {
            guard isReachable else { throw Offline() }

            let start = pageToken.flatMap(Int.init) ?? 0
            let end = min(start + pageSize, held.count)
            let page = Array(held[start ..< end])

            return StoredSessionPage(
                sessions: page,
                nextPageToken: end < held.count ? String(end) : nil
            )
        }

        func leaderboard(
            _: LeaderboardBoard,
            scope _: LeaderboardScope
        ) async throws -> Leaderboard {
            throw Offline()
        }
    }

    /// A defaults suite of its own, so tests neither see each other's ledger nor
    /// leave one behind on the machine that ran them.
    private func defaults() -> UserDefaults {
        let name = "journey-sync-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("a defaults suite is available")
            return .standard
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func session(_ offsetHours: Int) -> SessionRecord {
        SessionRecord(
            techniqueSlug: "box-breathing",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000)
                .addingTimeInterval(TimeInterval(offsetHours) * 3600),
            duration: .seconds(120),
            cyclesCompleted: 4,
            breathCount: 8,
            completed: true
        )
    }

    @Test("Acknowledged sessions are never sent twice")
    func acknowledgedSessionsAreNotResent() async {
        let sessions = SessionSpy([session(-1), session(-2)])
        let server = ServerSpy()
        let queue = SessionSyncQueue(
            sessions: sessions,
            scores: ScoreSpy(),
            journeys: server,
            ledger: SyncLedger(defaults: defaults())
        )

        await queue.sync()
        #expect(await server.received.count == 2)

        await queue.sync()
        #expect(await server.received.count == 2, "a second run has nothing to say")

        await sessions.record(session(0))
        await queue.sync()
        #expect(await server.received.count == 3, "and picks up what arrived since")
    }

    /// The failure that matters: a request that never landed must leave the
    /// ledger alone, or the session it carried is lost to the server forever.
    @Test("A failed send is retried on the next run")
    func aFailedSendIsRetried() async {
        let server = ServerSpy(isReachable: false)
        let queue = SessionSyncQueue(
            sessions: SessionSpy([session(-1)]),
            scores: ScoreSpy([BoltScore(seconds: 22)]),
            journeys: server,
            ledger: SyncLedger(defaults: defaults())
        )

        await queue.sync()
        #expect(await server.received.isEmpty)
        #expect(await server.receivedScores.isEmpty)

        await server.comeBackOnline()
        await queue.sync()
        #expect(await server.received.count == 1)
        #expect(await server.receivedScores.count == 1)
    }

    /// The reinstall path. The Keychain identity outlives the sessions file, so
    /// the server can hold history this device has lost — and what comes back
    /// must not be counted as something to send.
    @Test("Restored sessions land locally and are not echoed back")
    func restoredSessionsAreNotEchoedBack() async {
        let theirs = session(-48)
        let sessions = SessionSpy()
        let server = ServerSpy(held: [theirs])
        let queue = SessionSyncQueue(
            sessions: sessions,
            scores: ScoreSpy(),
            journeys: server,
            ledger: SyncLedger(defaults: defaults())
        )

        // The return value is "did local state change": true exactly once, on
        // the run that brought the history back — a caller re-reads on it, and
        // the server holding what it already sent us must not trigger that
        // re-read on every sync for the rest of the install.
        #expect(await queue.sync())
        #expect(await sessions.stored.map(\.id) == [theirs.id])
        #expect(await server.received.isEmpty, "it came from there")

        #expect(await !queue.sync())
        #expect(await sessions.stored.count == 1, "and is not duplicated on the way in")
        #expect(await server.received.isEmpty)
    }

    /// The restore is the only thing standing between a reinstall and a lost
    /// journal, and the server bounds what one call returns — so a queue that
    /// took the first page as the whole history would silently drop everything
    /// behind it, while the totals arriving alongside kept saying it was there.
    @Test("A restore keeps paging until the server runs out of history")
    func aRestorePagesUntilTheHistoryIsExhausted() async {
        let held = (1 ... 57).map { session(-$0) }
        let sessions = SessionSpy()
        let server = ServerSpy(held: held, pageSize: 20)
        let queue = SessionSyncQueue(
            sessions: sessions,
            scores: ScoreSpy(),
            journeys: server,
            ledger: SyncLedger(defaults: defaults())
        )

        #expect(await queue.sync())
        #expect(
            await Set(sessions.stored.map(\.id)) == Set(held.map(\.id)),
            "every page landed, not only the first"
        )
        #expect(await server.received.isEmpty, "and none of it was echoed back")

        #expect(await !queue.sync(), "a second run finds nothing new on any page")
        #expect(await sessions.stored.count == held.count)
    }

    /// The deletion round trip, and the reason it is a round trip at all: the
    /// server holds a copy the local delete cannot reach, so a reinstall would
    /// restore a session the person got rid of. The tombstone is the client's
    /// half of that promise and only leaves once the server has answered.
    @Test("A deleted session is deleted on the server, and only then forgotten")
    func deletionsReachTheServerBeforeTheTombstoneGoes() async {
        let deleted = session(-1)
        let sessions = SessionSpy([deleted, session(-2)])
        let server = ServerSpy(held: [deleted])
        let queue = SessionSyncQueue(
            sessions: sessions,
            scores: ScoreSpy(),
            journeys: server,
            tombstones: sessions,
            ledger: SyncLedger(defaults: defaults())
        )

        await queue.sync()
        await sessions.remove(deleted.id)
        #expect(await sessions.tombstoned == [deleted.id])

        await queue.sync()
        #expect(await server.deleted == [deleted.id])
        #expect(await sessions.tombstoned.isEmpty, "the server has forgotten it")
        #expect(
            await sessions.stored.count == 1,
            "and the restore in the same run cannot hand it back"
        )
    }

    /// The mirror of the failed send, and the more dangerous half: a tombstone
    /// dropped on a request that never landed leaves the server holding a
    /// session the person deleted, and the next restore returns it.
    @Test("A failed deletion keeps its tombstone")
    func aFailedDeletionIsRetried() async {
        let deleted = session(-1)
        let sessions = SessionSpy([deleted])
        let server = ServerSpy(isReachable: false, held: [deleted])
        let queue = SessionSyncQueue(
            sessions: sessions,
            scores: ScoreSpy(),
            journeys: server,
            tombstones: sessions,
            ledger: SyncLedger(defaults: defaults())
        )

        await sessions.remove(deleted.id)
        await queue.sync()
        #expect(await server.deleted.isEmpty)
        #expect(await sessions.tombstoned == [deleted.id])

        await server.comeBackOnline()
        await queue.sync()
        #expect(await server.deleted == [deleted.id])
        #expect(await sessions.tombstoned.isEmpty)
    }

    /// The ledger is pruned to what still exists, so it cannot grow without
    /// bound over years of daily practice.
    @Test("The ledger does not outlive the sessions it names")
    func theLedgerIsPruned() async {
        let store = defaults()
        let sessions = SessionSpy([session(-1)])
        let queue = SessionSyncQueue(
            sessions: sessions,
            scores: ScoreSpy(),
            journeys: ServerSpy(),
            ledger: SyncLedger(defaults: store)
        )

        await queue.sync()
        #expect(store.stringArray(forKey: "journey.acknowledgedSessions")?.count == 1)

        let emptied = SessionSyncQueue(
            sessions: SessionSpy(),
            scores: ScoreSpy(),
            journeys: ServerSpy(),
            ledger: SyncLedger(defaults: store)
        )
        await emptied.sync()
        #expect(store.stringArray(forKey: "journey.acknowledgedSessions")?.isEmpty == true)
    }
}
