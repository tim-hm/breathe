import Foundation
import OndKit
import Testing

/// The schedule list and its one promise: whatever the list says, the
/// notification center is re-synced from it — every add, edit, toggle, and
/// removal, with authorization asked for exactly where a person would expect
/// the question.
@MainActor
@Suite("Schedules")
struct ScheduleStoreTests {
    /// Remembers every sync and authorization ask, so a test can assert the
    /// notifier saw the same truth the list holds.
    private final class NotifierSpy: ScheduleNotifying, @unchecked Sendable {
        private(set) var synced: [[Schedule]] = []
        private(set) var authorizationRequests = 0

        func requestAuthorization() async -> Bool {
            authorizationRequests += 1
            return true
        }

        func sync(_ schedules: [Schedule]) async {
            synced.append(schedules)
        }
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "schedule-tests.\(name)")
        suite?.removePersistentDomain(forName: "schedule-tests.\(name)")
        return suite ?? .standard
    }

    private func schedule(
        slug: String = "box-breathing",
        hour: Int = 8,
        weekdays: Set<Weekday> = Weekday.weekdays
    ) -> Schedule {
        Schedule(
            techniqueSlug: slug,
            techniqueName: "Box Breathing",
            hour: hour,
            minute: 0,
            weekdays: weekdays
        )
    }

    /// Polls until the store's fire-and-forget notifier task has run.
    private func waitForSync(
        on spy: NotifierSpy,
        count: Int
    ) async throws {
        for _ in 0 ..< 200 {
            if spy.synced.count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for notifier sync \(count)")
    }

    @Test("Adding the first schedule asks permission and syncs the list")
    func addAsksAndSyncs() async throws {
        let spy = NotifierSpy()
        let store = ScheduleStore(notifier: spy, defaults: defaults("add"))
        let added = schedule()

        store.add(added)

        try await waitForSync(on: spy, count: 1)
        #expect(spy.authorizationRequests == 1)
        #expect(spy.synced.last == [added])
    }

    @Test("Schedules survive a relaunch")
    func persistsAcrossInstances() async throws {
        let spy = NotifierSpy()
        let suite = defaults("persist")
        let added = schedule(weekdays: [.saturday, .sunday])

        ScheduleStore(notifier: spy, defaults: suite).add(added)
        try await waitForSync(on: spy, count: 1)

        let relaunched = ScheduleStore(notifier: spy, defaults: suite)
        #expect(relaunched.schedules == [added])
    }

    @Test("Editing, toggling, and removing each re-sync the notifications")
    func mutationsResync() async throws {
        let spy = NotifierSpy()
        let store = ScheduleStore(notifier: spy, defaults: defaults("mutate"))
        var added = schedule()
        store.add(added)
        try await waitForSync(on: spy, count: 1)

        added.hour = 13
        store.update(added)
        try await waitForSync(on: spy, count: 2)
        #expect(spy.synced.last?.first?.hour == 13)

        store.setEnabled(false, for: added)
        try await waitForSync(on: spy, count: 3)
        #expect(spy.synced.last?.first?.isEnabled == false)

        store.remove(added)
        try await waitForSync(on: spy, count: 4)
        #expect(spy.synced.last == [])
        // One ask, on the add: permission belongs to the first schedule, not
        // to every edit after it.
        #expect(spy.authorizationRequests == 1)
    }

    @Test("The days label collapses the common shapes")
    func daysLabelReadsNaturally() {
        #expect(schedule(weekdays: Set(Weekday.allCases)).daysLabel == "Every day")
        #expect(schedule(weekdays: Weekday.weekdays).daysLabel == "Weekdays")
        #expect(schedule(weekdays: Weekday.weekend).daysLabel == "Weekends")
    }

    /// Whatever the locale starts the week on, a row of day toggles must show
    /// each day exactly once.
    @Test("The local week order covers all seven days")
    func localOrderIsComplete() {
        #expect(Set(Weekday.inLocalOrder) == Set(Weekday.allCases))
        #expect(Weekday.inLocalOrder.count == 7)
    }
}
