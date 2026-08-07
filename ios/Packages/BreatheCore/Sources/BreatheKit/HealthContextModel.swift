import Foundation
import Observation

/// Everything the coach may be told about this person's heart: one coarse
/// summary per metric, either of which may be absent when Health had too
/// little to say. Never constructed with both absent — no summary at all is
/// `nil` at the `HealthContextModel.context()` boundary, so a request either
/// carries evidence or carries nothing.
public struct CoachHealthContext: Sendable, Equatable {
    /// Resting heart rate, in beats per minute.
    public let restingHeartRate: HealthSnapshot?

    /// Heart-rate variability (SDNN), in milliseconds.
    public let heartRateVariability: HealthSnapshot?

    public init(restingHeartRate: HealthSnapshot?, heartRateVariability: HealthSnapshot?) {
        self.restingHeartRate = restingHeartRate
        self.heartRateVariability = heartRateVariability
    }
}

/// The in-app opt-in and the summary it unlocks: whether the coach may see
/// heart trends, and — only while it may — the coarse context a request
/// attaches.
///
/// The opt-in is deliberately a second switch on top of HealthKit's own
/// authorization, not a proxy for it. HealthKit never tells an app it was
/// refused read access — it simply reads nothing — and this model preserves
/// that on purpose: a denied grant and an empty Health store both fold to a
/// `nil` context, so nothing downstream can tell them apart, show a different
/// card, or say "you denied access". The only state this model owns is the
/// person's own in-app choice.
///
/// `UserDefaults` for the toggle, following `SessionSettings`: it is a
/// preference, not history — and unlike most preferences it must never move
/// onto the profile, because the server keeping "who shares heart data" would
/// be the first health-adjacent fact it stores.
@MainActor
@Observable
public final class HealthContextModel {
    /// How far back the daily series reach: eight weeks, enough history for
    /// `HealthSummaryBuilder` to clear its trend thresholds with room while
    /// staying a bounded, cheap pair of queries.
    public static let historyDays = 56

    private static let optInKey = "health.coachReadsHeartTrends"

    /// The in-app opt-in. Switching it on asks Health for read access —
    /// that is the first moment the app has any reason to read, and asking
    /// earlier would show a heart-data sheet to people who never opted in.
    public var coachReadsHeartTrends: Bool {
        didSet {
            defaults.set(coachReadsHeartTrends, forKey: Self.optInKey)
            guard coachReadsHeartTrends else { return }
            authorizationRequest = Task { await store.requestReadAuthorization() }
        }
    }

    /// The in-flight authorization ask, held so a test can await its
    /// completion — `didSet` cannot suspend, so the request runs as a task.
    public private(set) var authorizationRequest: Task<Void, Never>?

    private let store: any HealthStore
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    /// `now` is injectable so the folding is a pure function of the spy's
    /// series in host tests; the default is the clock.
    public init(
        store: any HealthStore,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.defaults = defaults
        self.now = now
        // Assigning in an initialiser does not run `didSet`, so restoring the
        // stored choice neither rewrites it nor re-asks Health for access.
        coachReadsHeartTrends = defaults.bool(forKey: Self.optInKey)
    }

    /// The context a coach request should carry right now: both metrics'
    /// series folded through `HealthSummaryBuilder`, or nil when the opt-in is
    /// off or Health yielded nothing — in which case the request goes exactly
    /// as it would have before this feature existed.
    public func context() async -> CoachHealthContext? {
        guard coachReadsHeartTrends else { return nil }

        let end = now()
        let start = end.addingTimeInterval(-TimeInterval(Self.historyDays) * 86400)

        let restingHeartRate = await HealthSummaryBuilder.snapshot(
            of: store.restingHeartRate(from: start, to: end),
            asOf: end
        )
        let heartRateVariability = await HealthSummaryBuilder.snapshot(
            of: store.heartRateVariability(from: start, to: end),
            asOf: end
        )

        guard restingHeartRate != nil || heartRateVariability != nil else { return nil }
        return CoachHealthContext(
            restingHeartRate: restingHeartRate,
            heartRateVariability: heartRateVariability
        )
    }
}
