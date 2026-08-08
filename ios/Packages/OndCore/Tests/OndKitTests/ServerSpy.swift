import Foundation
@testable import OndKit
import Testing

/// A server that is not there. Its own type rather than a boolean flag on the
/// throw site, so a test reads as the state it is describing.
struct Offline: Error {}

/// The journey half of the API, holding whatever a test says the server holds.
///
/// File of its own rather than beside the suite that drives it: it answers four
/// RPCs and pages the fifth, which is most of a file on its own, and both
/// `SessionSyncQueueTests` and anything else about what crosses the network
/// needs the same one.
actor ServerSpy: JourneySyncing {
    /// Every session id this "server" has been sent, including repeats — so
    /// a test can tell "sent once" from "sent again".
    private(set) var received: [UUID] = []
    private(set) var receivedScores: [UUID] = []
    private(set) var deleted: [UUID] = []
    /// How many times the restore has asked for a page, reachable or not —
    /// what tells a sync that skipped the round trip from one that made it
    /// and found nothing.
    private(set) var restoreCalls = 0
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

    /// Puts history behind the identity this "server" is being asked about —
    /// what signing in on a second device changes about the answer.
    func hold(_ sessions: [SessionRecord]) {
        held = sessions
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
        restoreCalls += 1
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
