import Foundation

/// The home screen's context rules: which exercise to offer again, and which
/// goal the intent wheel wakes up pointing at.
///
/// Deliberately the modest, on-device placeholder for M6's personalisation —
/// fixed rules, no learning. Pure on purpose: the hour arrives as an argument
/// rather than a clock read, so every rule is testable at any time of day.
public enum HomeSuggestion {
    /// The technique of the most recent session that is still in the
    /// catalogue. Sessions outlive catalogue entries, so a retired slug is
    /// skipped in favour of the session before it; nil means nothing to offer.
    public static func lastExercise(
        techniques: [Technique],
        history: [SessionRecord]
    ) -> Technique? {
        for record in history.reversed() {
            if let technique = techniques.first(where: { $0.slug == record.techniqueSlug }) {
                return technique
            }
        }
        return nil
    }

    /// The goal a given local hour reaches for. Boundaries are round numbers,
    /// not science: mornings wake up, working hours focus, evenings wind
    /// down, and everything after ten is about sleep.
    public static func goal(forHour hour: Int) -> TechniqueGoal {
        switch hour {
        case 5 ..< 11: .energy
        case 11 ..< 17: .focus
        case 17 ..< 22: .calm
        default: .sleep
        }
    }

    /// Which technique the wheel offers for `goal`: the one this person last
    /// used towards it, or the catalogue's first for it.
    ///
    /// Preferring their own is the whole of the personalisation here — a
    /// person who always reaches for 4-7-8 at night should not have to walk
    /// past coherent breathing to find it. Falls back across goals only when
    /// the catalogue has nothing for this one, so the wheel always begins
    /// something.
    public static func technique(
        for goal: TechniqueGoal,
        techniques: [Technique],
        history: [SessionRecord]
    ) -> Technique? {
        let forGoal = techniques.filter { $0.goal == goal }

        let theirs = history.reversed().lazy
            .compactMap { record in forGoal.first { $0.slug == record.techniqueSlug } }
            .first

        return theirs ?? forGoal.first ?? techniques.first
    }
}
