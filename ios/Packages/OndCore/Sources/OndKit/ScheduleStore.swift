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
public final class ScheduleStore: PersonalStore {
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

    /// Forgets the appointments, and unregisters the notifications they had
    /// already placed with iOS.
    ///
    /// The list itself is personal data and not merely configuration: a
    /// technique, an hour, a minute and a set of weekdays is a record of
    /// somebody's routine and of when they are at home.
    ///
    /// The pending requests are the half that would be *seen*. They live in the
    /// notification centre rather than in this app, they survive it being
    /// killed, and they fire on the lock screen naming the exercise — so a
    /// deletion that dropped the list alone would have the erased account
    /// announcing itself the next morning, on a schedule, to somebody who was
    /// told their practice was gone from this iPhone.
    ///
    /// Awaited rather than sent off in a `Task` like every other mutation here:
    /// the rest of this class is answering somebody editing a list who will not
    /// notice the resync, and this one is the last thing that happens before an
    /// erasure claims to be complete. `sync` takes the whole list by design, so
    /// an empty one removes every request this app owns and adds none.
    public func erase() async {
        schedules = []
        defaults.removeObject(forKey: Self.key)

        await notifier.sync(schedules)
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
