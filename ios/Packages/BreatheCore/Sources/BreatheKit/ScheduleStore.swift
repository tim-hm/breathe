import Foundation
import Observation

/// Whatever turns the schedule list into pending notifications.
///
/// A seam for the same reason `SessionCueing` is one: `UNUserNotificationCenter`
/// is an app-target concern that cannot run on the host under test, and the
/// store's real logic — what the list is and when it changed — does not need
/// it. The app hands in the real scheduler; tests hand in a spy.
public protocol ScheduleNotifying: Sendable {
    /// Asks the person for notification permission if it has never been asked.
    /// Answers whether notifications are allowed; a refusal does not stop
    /// schedules being kept, only heard.
    func requestAuthorization() async -> Bool
    /// Replaces every pending schedule notification with `schedules`' current
    /// truth. Called with the whole list, not a delta — replacing wholesale is
    /// idempotent, and a missed delta cannot strand a stale trigger.
    func sync(_ schedules: [Schedule]) async
}

/// The schedules, and the one place they change.
///
/// `UserDefaults` rather than a file store: this is configuration in the same
/// sense as `SessionSettings` — a handful of values, read at launch, written
/// on edit — not history that grows. Every mutation re-syncs the notification
/// center from the full list, so what iOS will fire and what this list says
/// can only drift between a change and the async resync completing.
@MainActor
@Observable
public final class ScheduleStore {
    private static let key = "schedules.list"

    public private(set) var schedules: [Schedule]

    private let defaults: UserDefaults
    private let notifier: any ScheduleNotifying

    public init(notifier: any ScheduleNotifying, defaults: UserDefaults = .standard) {
        self.notifier = notifier
        self.defaults = defaults
        schedules = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Schedule].self, from: $0) }
            ?? []
    }

    /// Adds a schedule and asks for notification permission in the same
    /// breath — the first schedule is the moment the promise in onboarding
    /// ("we'll ask when you set one up") comes due.
    public func add(_ schedule: Schedule) {
        schedules.append(schedule)
        persist()
        Task {
            _ = await notifier.requestAuthorization()
            await notifier.sync(schedules)
        }
    }

    /// Replaces the schedule with `schedule.id`, if it still exists.
    public func update(_ schedule: Schedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index] = schedule
        persistAndResync()
    }

    public func remove(_ schedule: Schedule) {
        schedules.removeAll { $0.id == schedule.id }
        persistAndResync()
    }

    /// Flips one schedule without opening the editor — the row's toggle.
    public func setEnabled(_ isEnabled: Bool, for schedule: Schedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index].isEnabled = isEnabled
        persistAndResync()
    }

    private func persistAndResync() {
        persist()
        Task { await notifier.sync(schedules) }
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(schedules) else { return }
        defaults.set(encoded, forKey: Self.key)
    }
}
