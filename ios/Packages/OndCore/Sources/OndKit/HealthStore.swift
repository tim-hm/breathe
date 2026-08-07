import Foundation

/// One day of a health metric, as the daily series queries answer: the start of
/// the day it summarises, and that day's average in the metric's display unit —
/// beats per minute for resting heart rate, milliseconds for HRV.
public struct DailyQuantity: Sendable, Equatable {
    public let day: Date
    public let value: Double

    public init(day: Date, value: Double) {
        self.day = day
        self.value = value
    }
}

/// One heart-rate reading: the moment it was taken and the rate in beats per
/// minute. The shape the in-session window queries answer in — nothing fetches
/// these yet, but the slice that does must not change the seam to do it.
public struct HeartRateSample: Sendable, Equatable {
    public let date: Date
    public let beatsPerMinute: Double

    public init(date: Date, beatsPerMinute: Double) {
        self.date = date
        self.beatsPerMinute = beatsPerMinute
    }
}

/// Everything this app needs from HealthKit, and nothing else.
///
/// A seam for the same reason `StoreFront` is one: what the app *decides* from a
/// series of daily readings — the means, the trends, the evidence thresholds —
/// is the interesting logic, and none of it should need a paired device and a
/// populated Health store to exercise. `HealthKitHealthStore` is the only type
/// in the repository that imports `HealthKit`.
///
/// Reads never distinguish "denied" from "no data". That is HealthKit's own
/// design — an app is not told it was refused read access, it simply reads
/// nothing — and this protocol preserves it deliberately: both cases answer an
/// empty series, so nothing built on top can say "you denied access" to
/// somebody who did, or wrongly promise data to somebody who merely has none.
public protocol HealthStore: Sendable {
    /// Asks the person for read access to the heart metrics. Shows the system
    /// sheet at most once; every later call resolves quietly. No answer comes
    /// back — see the note on reads above.
    func requestReadAuthorization() async

    /// Asks the person for write access to Mindful Minutes, and nothing else —
    /// reads are a separate ask, made only by the surface that uses them, so
    /// recording a session never shows a sheet about heart data.
    func requestWriteAuthorization() async

    /// Daily resting heart rate over `[start, end)`, in beats per minute,
    /// oldest first. Empty for no data, no access, or no Health store at all.
    func restingHeartRate(from start: Date, to end: Date) async -> [DailyQuantity]

    /// Daily heart-rate variability (SDNN) over `[start, end)`, in
    /// milliseconds, oldest first. Empty on the same terms as above.
    func heartRateVariability(from start: Date, to end: Date) async -> [DailyQuantity]

    /// Records the span from `start` to `end` as Mindful Minutes.
    ///
    /// Never fails from the caller's point of view: Health is an enhancement,
    /// and there is nothing a person who just finished breathing can do about a
    /// declined write except be needlessly told about it.
    func writeMindfulSession(from start: Date, to end: Date) async
}
