@testable import BreatheKit
import Foundation
import Testing

/// How a leaderboard failure reaches the screen.
///
/// Worth pinning because the mistake is invisible: every failure lands in the
/// same `catch`, and the cheapest thing to write there — one `.unreachable` for
/// all of them — presents the server's `AgeBandUnset`, the one refusal somebody
/// can actually do something about, as an outage to a person with full signal.
@MainActor
@Suite("Loading a leaderboard")
struct LeaderboardStateTests {
    private struct FailingJourneys: JourneySyncing {
        let error: JourneyRepositoryError

        func record(_: [SessionRecord]) async throws {}
        func delete(_: [SessionRecord.ID]) async throws {}
        func record(_: BoltScore) async throws {}

        func storedSessions() async throws -> [SessionRecord] {
            []
        }

        func leaderboard(
            _: LeaderboardBoard,
            scope _: LeaderboardScope
        ) async throws -> Leaderboard {
            throw error
        }
    }

    private actor EmptyStore: SessionRecording, BoltScoreRecording {
        func record(_: SessionRecord) async {}
        func remove(_: SessionRecord.ID) async {}
        func record(_: BoltScore) async {}

        func recordedSessions() async -> [SessionRecord] {
            []
        }

        func recordedScores() async -> [BoltScore] {
            []
        }

        func merge(_: [SessionRecord]) async -> Bool {
            false
        }
    }

    private func model(failingWith error: JourneyRepositoryError) -> JourneyModel {
        let store = EmptyStore()
        let journeys = FailingJourneys(error: error)
        let suite = "leaderboard-state-tests.\(UUID().uuidString)"
        let ledger = SyncLedger(defaults: UserDefaults(suiteName: suite) ?? .standard)

        return JourneyModel(
            sessions: store,
            scores: store,
            journeys: journeys,
            queue: SessionSyncQueue(
                sessions: store,
                scores: store,
                journeys: journeys,
                ledger: ledger
            )
        )
    }

    @Test("A missing birth-year band is an answerable question, not an outage")
    func aPreconditionIsItsOwnState() async {
        let model = model(failingWith: .failedPrecondition("caller has no birth year band"))
        model.scope = .ageBand

        await model.loadLeaderboard()

        #expect(model.leaderboard == .needsBirthYearBand)
    }

    /// Everything else stays one quiet notice, because there is no action behind
    /// any of it — including a contract this build cannot read.
    @Test("Every failure with nothing to do about it stays unreachable")
    func everythingElseIsUnreachable() async {
        for error in [
            JourneyRepositoryError.transport("connection refused"),
            .malformedResponse("unrecognised board"),
        ] {
            let model = model(failingWith: error)

            await model.loadLeaderboard()

            #expect(model.leaderboard == .unreachable)
        }
    }
}
