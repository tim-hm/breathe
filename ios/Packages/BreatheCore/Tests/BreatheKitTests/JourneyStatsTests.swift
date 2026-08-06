@testable import BreatheKit
import Foundation
import Testing

/// The local half of a definition the server also implements in SQL. Every case
/// here has a twin in `crates/api/tests/e2e/journey.rs`, and they have to agree:
/// a drift would show a person one streak on their phone and another on a
/// leaderboard drawn from the same sessions.
@Suite("Journey statistics")
struct JourneyStatsTests {
    /// A moment with no significance beyond being fixed, so that "today" in a
    /// test is a value rather than whenever the suite happens to run.
    private static let now = Date(timeIntervalSince1970: 1_777_000_000)

    private func calendar(offsetHours: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetHours * 3600) ?? .gmt
        return calendar
    }

    private func session(
        at startedAt: Date,
        minutes: Int = 2,
        breaths: Int = 8
    ) -> SessionRecord {
        SessionRecord(
            techniqueSlug: "box-breathing",
            startedAt: startedAt,
            duration: .seconds(minutes * 60),
            cyclesCompleted: 4,
            breathCount: breaths,
            completed: true
        )
    }

    @Test("A day is the reader's local day, not UTC")
    func localDaysFollowTheTimeZone() {
        // Two hours apart across a UTC midnight: consecutive days read in UTC,
        // one late evening read two hours west.
        let lateEvening = Date(timeIntervalSince1970: 1_776_812_400) // 23:00 UTC
        let sessions = [
            session(at: lateEvening),
            session(at: lateEvening.addingTimeInterval(2 * 3600)),
        ]

        let utc = JourneyStats(
            sessions: sessions,
            calendar: calendar(offsetHours: 0),
            now: Self.now
        )
        #expect(utc.bestStreakDays == 2)

        let west = JourneyStats(
            sessions: sessions,
            calendar: calendar(offsetHours: -2),
            now: Self.now
        )
        #expect(west.bestStreakDays == 1)
    }

    @Test("A streak holds until a whole local day has passed without a session")
    func aStreakSurvivesYesterday() {
        let day: TimeInterval = 24 * 3600
        let calendar = calendar(offsetHours: 0)

        let yesterdayOnly = JourneyStats(
            sessions: [session(at: Self.now.addingTimeInterval(-day))],
            calendar: calendar,
            now: Self.now
        )
        #expect(yesterdayOnly.currentStreakDays == 1)

        let paused = JourneyStats(
            sessions: [session(at: Self.now.addingTimeInterval(-2 * day))],
            calendar: calendar,
            now: Self.now
        )
        #expect(paused.currentStreakDays == 0)
        #expect(paused.bestStreakDays == 1, "a paused streak is not a forgotten one")

        let running = JourneyStats(
            sessions: [
                session(at: Self.now.addingTimeInterval(-day)),
                session(at: Self.now.addingTimeInterval(-3600)),
            ],
            calendar: calendar,
            now: Self.now
        )
        #expect(running.currentStreakDays == 2)
    }

    @Test("Several sessions in one day are one day of the streak")
    func repeatedDaysCountOnce() {
        let stats = JourneyStats(
            sessions: [
                session(at: Self.now.addingTimeInterval(-3600)),
                session(at: Self.now.addingTimeInterval(-7200)),
                session(at: Self.now.addingTimeInterval(-10800)),
            ],
            calendar: calendar(offsetHours: 0),
            now: Self.now
        )

        #expect(stats.sessions == 3)
        #expect(stats.currentStreakDays == 1)
        #expect(stats.bestStreakDays == 1)
    }

    /// Minutes are floored from the summed milliseconds rather than per session,
    /// which is also what the server does. Rounding each session first would
    /// lose a remainder every time somebody breathes for ninety seconds.
    @Test("Minutes are floored once, from the total")
    func minutesAreFlooredFromTheSum() {
        let stats = JourneyStats(
            sessions: [
                session(at: Self.now, minutes: 1, breaths: 5),
                session(at: Self.now, minutes: 1, breaths: 7),
            ],
            calendar: calendar(offsetHours: 0),
            now: Self.now
        )

        #expect(stats.minutes == 2)
        #expect(stats.breaths == 12)
    }

    @Test("A person with no sessions has nothing rather than a broken screen")
    func anEmptyHistoryIsValid() {
        let stats = JourneyStats(
            sessions: [],
            calendar: calendar(offsetHours: 0),
            now: Self.now
        )

        #expect(stats == .none)
    }
}
