import Foundation
import Observation

/// What the journey tab shows, and where it comes from.
///
/// Two sources with different rules, and the split is the whole design. The
/// person's own numbers — totals, streaks, history, best pause — are folded from
/// the local stores and are therefore always there, immediately, offline. The
/// leaderboards are other people, so they need a connection and say so quietly
/// when there isn't one. Nothing on this screen ever waits on the network.
@MainActor
@Observable
public final class JourneyModel {
    /// A board is either not asked for yet, on its way, here, out of reach, or
    /// waiting on an answer only this person can give.
    ///
    /// `unreachable` rather than an error case: being offline is a normal state
    /// for a phone, not a fault to report.
    public enum LeaderboardState: Sendable, Equatable {
        case idle
        case loading
        case loaded(Leaderboard)
        case unreachable
        /// The decade board, asked for by somebody who has not said which
        /// decade. Its own case because it is the one leaderboard failure with
        /// an action attached, and the scope picker can offer it before the
        /// server has the band: `LeaderboardView` guards on the *local* profile
        /// value, which is set the moment it is picked and outruns the sync.
        case needsBirthYearBand
    }

    public private(set) var stats: JourneyStats = .none
    /// Every session, newest first — the strip under the numbers.
    public private(set) var history: [SessionRecord] = []
    /// The best controlled pause on this device, `nil` before the first test.
    public private(set) var personalBest: Int?

    public private(set) var leaderboard: LeaderboardState = .idle
    public var board: LeaderboardBoard = .streak
    public var scope: LeaderboardScope = .global

    private let sessions: any SessionRecording
    private let scores: any BoltScoreRecording
    private let journeys: any JourneySyncing
    private let queue: SessionSyncQueue

    public init(
        sessions: any SessionRecording,
        scores: any BoltScoreRecording,
        journeys: any JourneySyncing,
        queue: SessionSyncQueue
    ) {
        self.sessions = sessions
        self.scores = scores
        self.journeys = journeys
        self.queue = queue
    }

    /// Reads the local stores and fills the screen.
    ///
    /// Called on every appearance. It touches no network, so it is as fast in
    /// airplane mode as anywhere else — which is exactly why the tab does not
    /// have a loading state for its own numbers.
    public func refresh() async {
        let recorded = await sessions.recordedSessions()

        stats = JourneyStats(sessions: recorded)
        history = recorded.sorted { $0.startedAt > $1.startedAt }
        personalBest = await scores.personalBest()
    }

    /// Pushes anything outstanding, then re-reads — a restore may have brought
    /// history back that this device had lost.
    ///
    /// Deliberately separate from `refresh()` so the screen is drawn before this
    /// is even started.
    public func sync() async {
        // Only a restore changes what is on this device, and it happens once
        // after a reinstall — re-reading both files on every sync would be work
        // for nothing on every run after it.
        if await queue.sync() {
            await refresh()
        }
    }

    /// Stores a controlled-pause measurement and answers whether it is a new
    /// best.
    ///
    /// The verdict is local, because the number a person is looking at has to be
    /// right with no signal. The server holds the same history and reaches the
    /// same answer for the leaderboard.
    @discardableResult
    public func record(boltSeconds seconds: Int) async -> Bool {
        let previous = personalBest
        await scores.record(BoltScore(seconds: seconds))
        // Derived from what is already in hand rather than re-read: the file was
        // just written, and the new best can only be one of these two.
        personalBest = max(previous ?? 0, seconds)

        // Not awaited: the result screen is already on its way, and the upload
        // has the rest of the app's lifetime to succeed in.
        Task { await queue.sync() }

        return previous.map { seconds > $0 } ?? true
    }

    /// Deletes one session from the journal and refolds everything derived
    /// from it — totals, streaks, the history strip — in the same breath, so
    /// the screen never shows numbers that still count a row it no longer has.
    public func delete(_ record: SessionRecord) async {
        await sessions.remove(record.id)
        await refresh()
    }

    /// Fetches the current board, if the network allows.
    ///
    /// The one failure that is separated out is the one somebody can do
    /// something about. Everything else — no signal, a server that is down, a
    /// board this build cannot read — is the same quiet notice, because there is
    /// no action behind any of them.
    public func loadLeaderboard() async {
        leaderboard = .loading

        do {
            leaderboard = try await .loaded(journeys.leaderboard(board, scope: scope))
        } catch JourneyRepositoryError.failedPrecondition {
            leaderboard = .needsBirthYearBand
        } catch {
            leaderboard = .unreachable
        }
    }
}
