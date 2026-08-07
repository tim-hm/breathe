import OndKit
import UserNotifications

/// The real `ScheduleNotifying`: schedules land as repeating local
/// notifications, one request per schedule per weekday.
///
/// Per-weekday rather than one daily trigger, because a calendar trigger with a
/// `weekday` component is the only way iOS repeats "Mondays at 08:00". The
/// fan-out is bounded — iOS caps pending requests at 64, which is nine
/// every-day schedules — and `sync` replacing wholesale means the cap can only
/// be hit by genuinely having that many appointments.
struct NotificationScheduler: ScheduleNotifying {
    /// Marks every request this app's schedules own, so a resync can clear
    /// them without touching any other notification the app may one day send.
    private static let prefix = "schedule-"

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        // Re-asking after a decision is a no-op that answers the standing
        // permission, so this is safe to call on every schedule creation.
        return await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func sync(_ schedules: [Schedule]) async {
        let center = UNUserNotificationCenter.current()

        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        )

        for schedule in schedules where schedule.isEnabled {
            for day in schedule.weekdays {
                try? await center.add(request(for: schedule, on: day))
            }
        }
    }

    private func request(for schedule: Schedule, on day: Weekday) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = schedule.techniqueName
        content.body = "Your \(schedule.timeLabel) practice is ready when you are."
        content.sound = .default

        var components = DateComponents()
        components.weekday = day.rawValue
        components.hour = schedule.hour
        components.minute = schedule.minute

        return UNNotificationRequest(
            identifier: "\(Self.prefix)\(schedule.id.uuidString)-\(day.rawValue)",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
    }
}
