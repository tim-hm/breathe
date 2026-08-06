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

/// The decade somebody was born in.
///
/// Bands by birth decade rather than by age, so a person's band never changes
/// under them. Optional everywhere: it exists so the age-band leaderboard can
/// compare like with like, and nobody has to answer it to use the app.
public enum BirthYearBand: String, Sendable, CaseIterable, Codable, Identifiable {
    case before1960
    case sixties
    case seventies
    case eighties
    case nineties
    case noughties
    case twentyTensOrLater

    public var id: Self {
        self
    }

    /// Phrased as a decade rather than as an age bracket — "born in the 1980s"
    /// is a fact about someone, where "aged 36–45" is a label being applied to
    /// them.
    public var title: String {
        switch self {
        case .before1960: "Before 1960"
        case .sixties: "The 1960s"
        case .seventies: "The 1970s"
        case .eighties: "The 1980s"
        case .nineties: "The 1990s"
        case .noughties: "The 2000s"
        case .twentyTensOrLater: "2010 or later"
        }
    }
}

/// What someone told the app about themselves.
///
/// Answers, not derived state: streaks and totals are computed from the sessions
/// on this device (see `JourneyStats`), so this stays something a person would
/// recognise as the things they typed. `Codable` because it is kept locally as
/// well as on the server — onboarding has to finish with no network.
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
    /// What the leaderboards call this person, and the whole of the opt-in to
    /// them. Empty means invisible to everyone else, which is where every
    /// profile starts.
    ///
    /// The server owns the final value — it trims, screens, and suffixes a name
    /// somebody already holds — so what comes back from a sync is what other
    /// people will see and may not be what was typed.
    public var displayName: String
    /// `nil` until they say, which most people never will.
    public var birthYearBand: BirthYearBand?

    /// How long a note may be, in Unicode scalars — the unit the server's
    /// validation and the database `CHECK` both count. Held here so the field
    /// can stop accepting input rather than letting someone write past the
    /// point where saving would fail.
    public static let maxIntentNoteLength = 500

    /// The same rule for a display name, in the same unit. The server also
    /// insists on a minimum of two.
    public static let maxDisplayNameLength = 24
    public static let minDisplayNameLength = 2

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
        intentNote: String,
        displayName: String = "",
        birthYearBand: BirthYearBand? = nil
    ) {
        self.goals = goals
        self.experienceLevel = experienceLevel
        self.reminderIntensity = reminderIntensity
        self.intentNote = intentNote
        self.displayName = displayName
        self.birthYearBand = birthYearBand
    }

    /// Written by hand for one reason: the synthesised decoder throws on a
    /// missing key even where the property has a default, so a profile stored
    /// before `displayName` existed would fail to decode and be discarded —
    /// silently asking somebody their onboarding questions again after an
    /// update. Every field is therefore optional on the way in.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        goals = try container.decodeIfPresent([TechniqueGoal].self, forKey: .goals) ?? []
        experienceLevel = try container.decodeIfPresent(
            ExperienceLevel.self,
            forKey: .experienceLevel
        )
        reminderIntensity = try container.decodeIfPresent(
            ReminderIntensity.self,
            forKey: .reminderIntensity
        ) ?? .never
        intentNote = try container.decodeIfPresent(String.self, forKey: .intentNote) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        birthYearBand = try container.decodeIfPresent(BirthYearBand.self, forKey: .birthYearBand)
    }
}
