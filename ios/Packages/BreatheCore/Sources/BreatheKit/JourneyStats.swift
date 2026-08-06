import Foundation

/// Everything the journey screen counts, folded from the sessions on this
/// device.
///
/// Computed locally and not fetched, because the app is offline-first: the tab
/// has to be fully populated in airplane mode, and a screen that waits on a
/// request to show somebody their own history is a screen that is sometimes
/// blank for no reason they can see.
///
/// The server computes the same numbers from the same sessions — it has to, for
/// the streak leaderboard — so the two definitions have to agree exactly. A
/// drift would show a person one streak on their phone and another on a board.
/// The rules both sides implement:
///
/// - A day is a **local** calendar day. A session at 23:30 belongs to the day
///   the person was living in, not to tomorrow in UTC.
/// - The **best** streak is the longest run of consecutive days there has ever
///   been. It never decreases.
/// - The **current** streak is a run ending today *or yesterday*. A streak is
///   not broken until a whole local day has passed with no session, so somebody
///   who has not breathed yet this morning has not lost anything.
public struct JourneyStats: Sendable, Equatable {
    public let sessions: Int
    public let breaths: Int
    /// Whole minutes, rounded down, from the summed milliseconds — so a hundred
    /// short sessions do not each lose their remainder.
    public let minutes: Int
    public let currentStreakDays: Int
    public let bestStreakDays: Int

    /// What somebody has before their first session.
    public static let none = Self(
        sessions: 0,
        breaths: 0,
        minutes: 0,
        currentStreakDays: 0,
        bestStreakDays: 0
    )

    /// - Parameters:
    ///   - sessions: every session on this device, in any order.
    ///   - calendar: carries the time zone the days are counted in. The default
    ///     follows the device, so flying somewhere changes the answer — which is
    ///     correct, and is the same reason the server takes the offset per
    ///     request rather than storing it.
    ///   - now: the moment "today" is measured from. A parameter so a test can
    ///     name a day rather than wait for one.
    public init(
        sessions records: [SessionRecord],
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = .now
    ) {
        sessions = records.count
        breaths = records.reduce(0) { $0 + $1.breathCount }
        minutes = records.reduce(0) { $0 + $1.durationMs } / 60000

        let days = Set(records.map { calendar.startOfDay(for: $0.startedAt) }).sorted()

        var best = 0
        var run = 0
        var previous: Date?
        for day in days {
            let isConsecutive = previous.flatMap {
                calendar.dateComponents([.day], from: $0, to: day).day
            } == 1
            run = isConsecutive ? run + 1 : 1
            best = max(best, run)
            previous = day
        }
        bestStreakDays = best

        // `days` is ascending, so `run` is the length of the run ending on the
        // last day — the only run that can still be current.
        let today = calendar.startOfDay(for: now)
        let daysSinceLast = days.last.flatMap {
            calendar.dateComponents([.day], from: $0, to: today).day
        }
        currentStreakDays = (daysSinceLast ?? .max) <= 1 ? run : 0
    }

    private init(
        sessions: Int,
        breaths: Int,
        minutes: Int,
        currentStreakDays: Int,
        bestStreakDays: Int
    ) {
        self.sessions = sessions
        self.breaths = breaths
        self.minutes = minutes
        self.currentStreakDays = currentStreakDays
        self.bestStreakDays = bestStreakDays
    }
}
