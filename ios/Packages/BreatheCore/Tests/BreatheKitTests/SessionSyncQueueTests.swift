@testable import BreatheKit
import Foundation
import Testing

/// The bookkeeping that decides what crosses the network.
///
/// Worth testing because both ways of getting it wrong are invisible: a ledger
/// that forgets sends a person's whole history on every launch, and one that
/// remembers too eagerly loses the sessions a failed request never delivered.
@Suite("Session sync queue")
struct SessionSyncQueueTests {
    private actor SessionSpy: SessionRecording {
        private(set) var stored: [SessionRecord]

        init(_ stored: [SessionRecord] = []) {
            self.stored = stored
        }

        func record(_ session: SessionRecord) async {
            stored.append(session)
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
        private var isReachable: Bool
        private let held: [SessionRecord]

        init(isReachable: Bool = true, held: [SessionRecord] = []) {
            self.isReachable = isReachable
            self.held = held
        }

        func comeBackOnline() {
            isReachable = true
        }

        func record(_ sessions: [SessionRecord]) async throws {
            guard isReachable else { throw Offline() }
            received.append(contentsOf: sessions.map(\.id))
        }

        func record(_ score: BoltScore) async throws {
            guard isReachable else { throw Offline() }
            receivedScores.append(score.id)
        }

        func storedSessions() async throws -> [SessionRecord] {
            guard isReachable else { throw Offline() }
            return held
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
