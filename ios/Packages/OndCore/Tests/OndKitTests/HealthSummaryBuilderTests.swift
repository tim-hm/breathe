import Foundation
@testable import OndKit
import Testing

/// The evidence thresholds are the product decision under test: the coach sees
/// a trend only when the series can support one, and below that it sees
/// absence — never a zero, never a guess.
@Suite("Health summary thresholds")
struct HealthSummaryBuilderTests {
    /// A moment with no significance beyond being fixed, so that "today" in a
    /// test is a value rather than whenever the suite happens to run.
    private static let now = Date(timeIntervalSince1970: 1_777_000_000)

    /// One reading, `daysAgo` whole days before `now`.
    private func reading(daysAgo: Int, _ value: Double) -> DailyQuantity {
        DailyQuantity(day: Self.now.addingTimeInterval(-Double(daysAgo) * 86400), value: value)
    }

    /// Seven recent days of one steady value — enough for a mean on its own,
    /// and the block every trend test builds on.
    private func steadyWeek(of value: Double) -> [DailyQuantity] {
        (0 ... 6).map { reading(daysAgo: $0, value) }
    }

    @Test("An empty series is no snapshot at all")
    func emptySeries() {
        #expect(HealthSummaryBuilder.snapshot(of: [], asOf: Self.now) == nil)
    }

    @Test("History with nothing recent is no snapshot at all")
    func staleSeries() {
        let series = (10 ... 30).map { reading(daysAgo: $0, 60) }
        #expect(HealthSummaryBuilder.snapshot(of: series, asOf: Self.now) == nil)
    }

    @Test("A few recent days make a mean but never a trend")
    func recentOnly() {
        let series = (0 ... 4).map { reading(daysAgo: $0, 61) }
        let snapshot = HealthSummaryBuilder.snapshot(of: series, asOf: Self.now)
        #expect(snapshot == HealthSnapshot(sevenDayMean: 61, trendFromBaseline: nil))
    }

    @Test("The trend is the recent mean against everything older")
    func trendMath() {
        let series = steadyWeek(of: 60)
            + [reading(daysAgo: 14, 65), reading(daysAgo: 21, 65), reading(daysAgo: 28, 65)]
        let snapshot = HealthSummaryBuilder.snapshot(of: series, asOf: Self.now)
        #expect(snapshot == HealthSnapshot(sevenDayMean: 60, trendFromBaseline: -5))
    }

    @Test("Nine days of data withhold the trend; the tenth grants it")
    func minimumDaysEdge() {
        // Six recent, three old: nine days across a 24-day span — everything a
        // trend needs except the tenth day.
        let nine = (0 ... 5).map { reading(daysAgo: $0, 60) }
            + [reading(daysAgo: 10, 65), reading(daysAgo: 17, 65), reading(daysAgo: 24, 65)]
        #expect(HealthSummaryBuilder.snapshot(of: nine, asOf: Self.now)?.trendFromBaseline == nil)

        let ten = nine + [reading(daysAgo: 6, 60)]
        #expect(HealthSummaryBuilder.snapshot(of: ten, asOf: Self.now)?.trendFromBaseline == -5)
    }

    @Test("A 20-day span withholds the trend; 21 days grant it")
    func minimumSpanEdge() {
        let narrow = steadyWeek(of: 60)
            + [reading(daysAgo: 14, 65), reading(daysAgo: 17, 65), reading(daysAgo: 20, 65)]
        #expect(HealthSummaryBuilder.snapshot(of: narrow, asOf: Self.now)?.trendFromBaseline == nil)

        let wide = steadyWeek(of: 60)
            + [reading(daysAgo: 15, 65), reading(daysAgo: 18, 65), reading(daysAgo: 21, 65)]
        #expect(HealthSummaryBuilder.snapshot(of: wide, asOf: Self.now)?.trendFromBaseline == -5)
    }

    @Test("Means and trends round to whole units, halves away from zero")
    func rounding() {
        // Recent mean 62.5; baseline mean 65.0 → delta -2.5. Both halves must
        // move away from zero: 63 up, -3 down.
        let series = [reading(daysAgo: 0, 62), reading(daysAgo: 1, 63)]
            + (10 ... 21).map { reading(daysAgo: $0, 65) }
        let snapshot = HealthSummaryBuilder.snapshot(of: series, asOf: Self.now)
        #expect(snapshot == HealthSnapshot(sevenDayMean: 63, trendFromBaseline: -3))
    }

    @Test("Readings dated after now are not evidence")
    func futureReadings() {
        let tomorrow = [reading(daysAgo: -1, 200)]
        #expect(HealthSummaryBuilder.snapshot(of: tomorrow, asOf: Self.now) == nil)

        let snapshot = HealthSummaryBuilder.snapshot(
            of: steadyWeek(of: 60) + tomorrow,
            asOf: Self.now
        )
        #expect(snapshot?.sevenDayMean == 60)
    }
}
