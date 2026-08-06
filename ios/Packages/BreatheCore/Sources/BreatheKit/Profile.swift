import Foundation

/// How much breathwork someone has done before.
///
/// Chooses what the app explains, never what it offers — every technique is
/// available at every level. Absent rather than "unspecified": a profile exists
/// before anyone has been asked, and `ExperienceLevel?` says so without adding a
/// case every `switch` would have to carry.
public enum ExperienceLevel: String, Sendable, CaseIterable, Codable, Identifiable {
    case new
    case occasional
    case regular

    public var id: Self {
        self
    }

    /// First person, and phrased as something a person would say rather than as
    /// a tier they are being sorted into.
    public var title: String {
        switch self {
        case .new: "I'm new to this"
        case .occasional: "I've tried it a few times"
        case .regular: "I practise already"
        }
    }

    public var detail: String {
        switch self {
        case .new: "We'll explain what's happening as you go."
        case .occasional: "We'll keep the guidance light."
        case .regular: "Straight to the breathing."
        }
    }
}

/// How much the app is invited to ask for someone's attention.
///
/// `never` is the default in every direction — the stored default, the proto
/// zero value, and what an unreadable preference falls back to — so nothing
/// that goes wrong can turn silence into a notification. M7 asks for
/// notification permission only when this moves off it.
public enum ReminderIntensity: String, Sendable, CaseIterable, Codable, Identifiable {
    case never
    case gentle
    case daily

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .never: "Never"
        case .gentle: "Now and then"
        case .daily: "Once a day"
        }
    }

    /// Written so that `never` reads as a choice rather than as opting out of
    /// the app. Nobody should feel they have picked the lesser option.
    public var detail: String {
        switch self {
        case .never: "No notifications at all. Open the app when you want it."
        case .gentle: "An occasional nudge. Nothing counts a missed day against you."
        case .daily: "One reminder a day."
        }
    }
}

/// What someone told the app about themselves.
///
/// Answers, not derived state: streaks and totals arrive in M5 and live
/// elsewhere, so this stays something a person would recognise as the things
/// they typed. `Codable` because it is kept locally as well as on the server —
/// onboarding has to finish with no network.
public struct Profile: Sendable, Equatable, Codable {
    /// What they are here for, in the order they picked. Empty is a real
    /// answer: someone can skip the question, and it does not mean "all of
    /// them".
    public var goals: [TechniqueGoal]
    /// `nil` until they answer.
    public var experienceLevel: ExperienceLevel?
    public var reminderIntensity: ReminderIntensity
    /// Why they are here, in their own words. Empty is the normal state.
    public var intentNote: String

    /// How long a note may be, matching the limit the server enforces. Held here
    /// so the field can stop accepting characters rather than letting someone
    /// write past the point where saving would fail.
    public static let maxIntentNoteLength = 500

    /// A profile of unanswered questions — what a person has before onboarding,
    /// and what the server returns for an identity that has never written one.
    public static let unanswered = Self(
        goals: [],
        experienceLevel: nil,
        reminderIntensity: .never,
        intentNote: ""
    )

    public init(
        goals: [TechniqueGoal],
        experienceLevel: ExperienceLevel?,
        reminderIntensity: ReminderIntensity,
        intentNote: String
    ) {
        self.goals = goals
        self.experienceLevel = experienceLevel
        self.reminderIntensity = reminderIntensity
        self.intentNote = intentNote
    }
}
