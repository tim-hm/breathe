import Foundation

/// A day of the week, numbered as `Calendar` numbers them: 1 is Sunday,
/// 7 is Saturday.
///
/// That convention is load-bearing, not aesthetic — `rawValue` is handed
/// straight to `DateComponents.weekday` when a schedule becomes notification
/// triggers, and any friendlier numbering would fire every reminder on the
/// wrong day.
public enum Weekday: Int, Sendable, CaseIterable, Codable, Identifiable, Comparable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    public var id: Self {
        self
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// "Mon" — the short symbol for pills and summaries, in the current locale.
    public var shortName: String {
        Calendar.current.shortWeekdaySymbols[rawValue - 1]
    }

    /// The week as this locale lays it out — Monday-first in the UK, Sunday-first
    /// in the US — for any row of day toggles, so the picker reads like the
    /// person's own calendar app.
    public static var inLocalOrder: [Weekday] {
        let first = Calendar.current.firstWeekday
        return (0 ..< 7).compactMap { Weekday(rawValue: (first - 1 + $0) % 7 + 1) }
    }

    /// Monday to Friday, the "every workday" preset.
    public static let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    /// Saturday and Sunday.
    public static let weekend: Set<Weekday> = [.saturday, .sunday]
}

/// A standing appointment with one technique: a time, the days it recurs, and
/// whether it is currently ringing.
///
/// Local through and through — the schedule lives in `UserDefaults` and rings
/// as local notifications, so it works with the radio off and tells the server
/// nothing ([[offline-first-design]]).
public struct Schedule: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    /// The technique it opens with, by the slug the catalogue keeps stable.
    public var techniqueSlug: String
    /// Denormalised so the notification can name the exercise even when the
    /// catalogue has not been fetched this launch.
    public var techniqueName: String
    /// 24-hour clock, local time. Hour and minute rather than a `Date`: the
    /// appointment is "07:00 wherever I am", and a `Date` would pin it to the
    /// time zone it was created in.
    public var hour: Int
    public var minute: Int
    /// The days it fires. Never empty — a schedule with no days is deleted,
    /// not kept as a trap that looks set and never rings.
    public var weekdays: Set<Weekday>
    /// Off keeps the schedule configured but silent — the difference between
    /// pausing a habit and dismantling it.
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        techniqueSlug: String,
        techniqueName: String,
        hour: Int,
        minute: Int,
        weekdays: Set<Weekday>,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.techniqueSlug = techniqueSlug
        self.techniqueName = techniqueName
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.isEnabled = isEnabled
    }

    /// "07:00" as this locale writes it, for rows and notification bodies.
    public var timeLabel: String {
        let components = DateComponents(hour: hour, minute: minute)
        guard let date = Calendar.current.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// "Every day", "Weekdays", "Weekends", or "Mon, Wed, Fri" — whichever
    /// shortest phrase tells the truth.
    public var daysLabel: String {
        switch weekdays {
        case Set(Weekday.allCases): "Every day"
        case Weekday.weekdays: "Weekdays"
        case Weekday.weekend: "Weekends"
        default: Weekday.inLocalOrder
            .filter(weekdays.contains)
            .map(\.shortName)
            .joined(separator: ", ")
        }
    }
}
