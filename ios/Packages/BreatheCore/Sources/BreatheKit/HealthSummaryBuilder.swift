import Foundation

/// What the coach may know about one heart metric: how it has run this week,
/// and — with enough evidence — how that compares to the weeks before.
///
/// Whole numbers on purpose. The product decision is that the coach sees coarse
/// trends, never readings: a mean rounded to the beat or the millisecond is
/// enough to shape guidance, and precision beyond that only makes the summary
/// look like a diagnosis.
public struct HealthSnapshot: Sendable, Equatable {
    /// The last seven days' mean, rounded to a whole unit.
    public let sevenDayMean: Int

    /// How the last seven days sit against the weeks before them — positive is
    /// higher than baseline. Nil when the series is too thin to support a
    /// trend; see `HealthSummaryBuilder`.
    public let trendFromBaseline: Int?

    public init(sevenDayMean: Int, trendFromBaseline: Int?) {
        self.sevenDayMean = sevenDayMean
        self.trendFromBaseline = trendFromBaseline
    }
}

/// Folds a daily series — typically the last eight weeks of one metric — into
/// the coarse summary the coach is allowed to see.
///
/// Pure on purpose: everything load-bearing about health data happens here, in
/// a function of values, so every threshold below is host-testable without a
/// Health store. The seam (`HealthStore`) only fetches.
///
/// The minimum-evidence thresholds exist because an under-evidenced trend is
/// worse than none: "your resting heart rate is up" computed from four
/// scattered readings would send the coach chasing noise, and a person trusts
/// exactly one such wrong sentence. Below threshold the answer is absence —
/// a nil trend, or no snapshot at all — never a zero, because zero is a
/// reading and absence is not.
public enum HealthSummaryBuilder {
    /// Days of history a trend needs before it is worth stating.
    public static let minimumTrendDays = 10

    /// The shortest stretch, first day to last, a trend may be drawn across.
    /// Ten readings inside a fortnight say nothing about a baseline.
    public static let minimumTrendSpanDays = 21

    /// How many days back from `now` count as "recent" — the window the mean
    /// summarises and the trend compares against everything older.
    public static let recentDays = 7

    /// A calendar-free day. Coarse arithmetic is the point: an hour of daylight
    /// saving cannot move a whole-unit weekly mean, and a fixed day keeps this
    /// a pure function of its arguments rather than of a time zone.
    private static let day: TimeInterval = 86400

    /// The summary `series` supports, or nil when the recent window is empty.
    ///
    /// `series` is a daily series — at most one entry per day, as the
    /// `HealthStore` queries answer. Entries dated after `now` are ignored:
    /// a device clock that has been forward and back again is not evidence.
    public static func snapshot(of series: [DailyQuantity], asOf now: Date) -> HealthSnapshot? {
        let usable = series.filter { $0.day <= now }
        let cutoff = now.addingTimeInterval(-TimeInterval(recentDays) * day)

        let recent = usable.filter { $0.day > cutoff }
        guard !recent.isEmpty else { return nil }
        let recentMean = mean(of: recent)

        return HealthSnapshot(
            sevenDayMean: Int(recentMean.rounded()),
            trendFromBaseline: trend(of: usable, olderThan: cutoff, against: recentMean)
        )
    }

    /// The rounded delta of the recent mean against everything before the
    /// window, or nil when the series is too thin to clear the thresholds.
    private static func trend(
        of usable: [DailyQuantity],
        olderThan cutoff: Date,
        against recentMean: Double
    ) -> Int? {
        let baseline = usable.filter { $0.day <= cutoff }
        let days = usable.map(\.day)
        guard
            !baseline.isEmpty,
            usable.count >= minimumTrendDays,
            let first = days.min(),
            let last = days.max(),
            last.timeIntervalSince(first) >= TimeInterval(minimumTrendSpanDays) * day
        else {
            return nil
        }

        return Int((recentMean - mean(of: baseline)).rounded())
    }

    /// The arithmetic mean of a non-empty series' values.
    private static func mean(of series: [DailyQuantity]) -> Double {
        series.reduce(0) { $0 + $1.value } / Double(series.count)
    }
}
