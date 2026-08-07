@testable import BreatheKit
import Foundation
import Testing

/// The opt-in state machine and the folding behind the coach's heart context:
/// off means Health is never touched, on means the series fold through the
/// summary builder, and "nothing to say" is indistinguishable from "not
/// allowed to look" — the model never learns which it was.
@MainActor
@Suite("Coach health context")
struct HealthContextModelTests {
    /// Answers from a script and remembers every call, so a test can prove
    /// Health was never touched — not merely that nothing came back.
    private actor ScriptedHealthStore: HealthStore {
        private(set) var readAuthorizationRequests = 0
        private(set) var queries = 0
        private let restingHeartRate: [DailyQuantity]
        private let heartRateVariability: [DailyQuantity]

        init(
            restingHeartRate: [DailyQuantity] = [],
            heartRateVariability: [DailyQuantity] = []
        ) {
            self.restingHeartRate = restingHeartRate
            self.heartRateVariability = heartRateVariability
        }

        func requestReadAuthorization() async {
            readAuthorizationRequests += 1
        }

        func requestWriteAuthorization() async {}

        func restingHeartRate(from _: Date, to _: Date) async -> [DailyQuantity] {
            queries += 1
            return restingHeartRate
        }

        func heartRateVariability(from _: Date, to _: Date) async -> [DailyQuantity] {
            queries += 1
            return heartRateVariability
        }

        func writeMindfulSession(from _: Date, to _: Date) async {}
    }

    private nonisolated static let now = Date(timeIntervalSince1970: 1_777_000_000)

    /// A daily series: `value` on each of the last seven days, `baseline` on
    /// ten spread days before them — enough evidence for a trend by
    /// `HealthSummaryBuilder`'s own thresholds.
    private static func trendingSeries(recent value: Double, baseline: Double) -> [DailyQuantity] {
        let baselineDays = stride(from: -48, through: -12, by: 4).map { offset in
            DailyQuantity(day: day(offset), value: baseline)
        }
        let recentDays = (-6 ... 0).map { offset in
            DailyQuantity(day: day(offset), value: value)
        }
        return baselineDays + recentDays
    }

    private static func day(_ offset: Int) -> Date {
        now.addingTimeInterval(TimeInterval(offset) * 86400)
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "health-context-tests.\(UUID().uuidString)"))
    }

    private func model(
        store: ScriptedHealthStore,
        defaults: UserDefaults
    ) -> HealthContextModel {
        HealthContextModel(store: store, defaults: defaults, now: { Self.now })
    }

    @Test("Opt-in off asks Health nothing and yields no context")
    func optInOffTouchesNothing() async throws {
        let store = ScriptedHealthStore(
            restingHeartRate: Self.trendingSeries(recent: 62, baseline: 58)
        )
        let model = try model(store: store, defaults: defaults())

        #expect(await model.context() == nil)
        #expect(await store.queries == 0)
        #expect(await store.readAuthorizationRequests == 0)
    }

    @Test("Switching the opt-in on asks Health for read access")
    func optInOnRequestsAuthorization() async throws {
        let store = ScriptedHealthStore()
        let model = try model(store: store, defaults: defaults())

        model.coachReadsHeartTrends = true
        await model.authorizationRequest?.value

        #expect(await store.readAuthorizationRequests == 1)
    }

    @Test("Both series fold through the summary builder into one context")
    func seriesFoldIntoContext() async throws {
        let store = ScriptedHealthStore(
            restingHeartRate: Self.trendingSeries(recent: 62, baseline: 58),
            heartRateVariability: Self.trendingSeries(recent: 45, baseline: 51)
        )
        let model = try model(store: store, defaults: defaults())
        model.coachReadsHeartTrends = true

        let context = try #require(await model.context())
        #expect(context.restingHeartRate == HealthSnapshot(sevenDayMean: 62, trendFromBaseline: 4))
        #expect(
            context.heartRateVariability
                == HealthSnapshot(sevenDayMean: 45, trendFromBaseline: -6)
        )
    }

    @Test("One silent metric leaves the other's evidence standing")
    func oneMetricSuffices() async throws {
        let store = ScriptedHealthStore(
            heartRateVariability: Self.trendingSeries(recent: 45, baseline: 51)
        )
        let model = try model(store: store, defaults: defaults())
        model.coachReadsHeartTrends = true

        let context = try #require(await model.context())
        #expect(context.restingHeartRate == nil)
        #expect(context.heartRateVariability?.sevenDayMean == 45)
    }

    /// Empty series are what a denied read grant answers too, so this test is
    /// the denied case as much as the no-data one — deliberately the same.
    @Test("Nothing in Health is no context, not an empty one")
    func emptyHealthIsNoContext() async throws {
        let model = try model(store: ScriptedHealthStore(), defaults: defaults())
        model.coachReadsHeartTrends = true

        #expect(await model.context() == nil)
    }

    @Test("The opt-in survives a relaunch, and restoring it re-asks nothing")
    func optInPersists() async throws {
        let defaults = try defaults()
        let first = ScriptedHealthStore()
        model(store: first, defaults: defaults).coachReadsHeartTrends = true

        let second = ScriptedHealthStore()
        let relaunched = model(store: second, defaults: defaults)

        #expect(relaunched.coachReadsHeartTrends)
        #expect(
            await second.readAuthorizationRequests == 0,
            "restoring a stored choice is not a new grant to ask for"
        )
    }
}
