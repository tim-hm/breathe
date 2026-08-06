import Foundation

/// What the home screen leads with before the catalogue: the person's own
/// last exercise, or a time-of-day suggestion while there is no history yet.
///
/// Deliberately the modest, on-device placeholder for M6's personalisation —
/// fixed rules, no learning. Pure on purpose: the hour arrives as an argument
/// rather than a clock read, so every rule is testable at any time of day.
public enum HomeSuggestion: Sendable, Equatable {
    /// The technique of the most recent recorded session.
    case beginAgain(Technique)
    /// A goal picked from the local hour, and the prompt that frames it.
    case timeOfDay(Technique, prompt: String)

    /// - Parameters:
    ///   - techniques: the loaded catalogue. Empty means no suggestion.
    ///   - history: recorded sessions, oldest first, as `SessionRecording`
    ///     returns them.
    ///   - hour: the local hour, 0...23.
    public static func make(
        techniques: [Technique],
        history: [SessionRecord],
        hour: Int
    ) -> HomeSuggestion? {
        guard !techniques.isEmpty else { return nil }

        // Sessions outlive catalogue entries, so the slug may no longer
        // resolve; the time-of-day rule is the fallback, not an error.
        if let last = history.last,
           let technique = techniques.first(where: { $0.slug == last.techniqueSlug })
        {
            return .beginAgain(technique)
        }

        let (goal, prompt) = slot(for: hour)
        guard let match = techniques.first(where: { $0.goal == goal }) else {
            return .timeOfDay(techniques[0], prompt: "Two guided minutes?")
        }
        return .timeOfDay(match, prompt: prompt)
    }

    public var technique: Technique {
        switch self {
        case let .beginAgain(technique), let .timeOfDay(technique, _): technique
        }
    }

    /// The line above the technique's name on the card.
    public var prompt: String {
        switch self {
        case .beginAgain: "Begin again"
        case let .timeOfDay(_, prompt): prompt
        }
    }

    /// Which goal a given hour reaches for, and how the card says so.
    ///
    /// Boundaries are round numbers, not science: mornings wake up, working
    /// hours focus, evenings wind down, and everything after ten is about
    /// sleep.
    private static func slot(for hour: Int) -> (TechniqueGoal, String) {
        switch hour {
        case 5 ..< 11: (.energy, "Morning — start the day awake?")
        case 11 ..< 17: (.focus, "Afternoon — settle in to focus?")
        case 17 ..< 22: (.calm, "Evening — wind down?")
        default: (.sleep, "Late — breathe your way to sleep?")
        }
    }
}
