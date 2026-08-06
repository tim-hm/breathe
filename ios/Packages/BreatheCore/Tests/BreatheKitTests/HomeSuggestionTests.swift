import BreatheKit
import Foundation
import Testing

/// The home screen's rules are trivial to eyeball and easy to get quietly
/// wrong: an off-by-one hour boundary points the wheel at bellows breath at
/// bedtime, and a goal the catalogue stopped serving must still resolve to
/// something Begin can start.
@Suite("Choosing what the home screen leads with")
struct HomeSuggestionTests {
    private func technique(slug: String, goal: TechniqueGoal) -> Technique {
        Technique(
            id: slug,
            slug: slug,
            name: slug,
            summary: "",
            goal: goal,
            stages: [Stage(phases: [Phase(kind: .inhale, duration: .seconds(4))], cycles: 1)],
            recommendedRounds: 1
        )
    }

    private func session(slug: String) -> SessionRecord {
        SessionRecord(
            techniqueSlug: slug,
            startedAt: Date(timeIntervalSince1970: 0),
            duration: .seconds(60),
            cyclesCompleted: 1,
            breathCount: 1,
            completed: true
        )
    }

    private var catalogue: [Technique] {
        [
            technique(slug: "box", goal: .calm),
            technique(slug: "478", goal: .sleep),
            technique(slug: "bellows", goal: .energy),
            technique(slug: "coherent", goal: .focus),
        ]
    }

    @Test("The wheel offers what this person last used towards the goal")
    func prefersTheirOwnTechnique() {
        let catalogue = catalogue + [technique(slug: "extended", goal: .sleep)]

        let chosen = HomeSuggestion.technique(
            for: .sleep,
            techniques: catalogue,
            history: [session(slug: "extended"), session(slug: "bellows")]
        )

        #expect(chosen?.slug == "extended", "the bellows session is for another goal")
    }

    @Test("With no history for the goal, the catalogue's first for it wins")
    func fallsBackToTheCatalogue() {
        let chosen = HomeSuggestion.technique(
            for: .sleep,
            techniques: catalogue,
            history: [session(slug: "box")]
        )

        #expect(chosen?.slug == "478")
    }

    /// The wheel only offers goals the catalogue can serve, but a technique
    /// retired between load and tap must still start something rather than
    /// leaving Begin pointing at nothing.
    @Test("A goal the catalogue cannot serve still yields a technique")
    func unservedGoalStillStarts() {
        let sleepless = [technique(slug: "box", goal: .calm)]

        #expect(
            HomeSuggestion.technique(for: .sleep, techniques: sleepless, history: [])?.slug == "box"
        )
        #expect(HomeSuggestion.technique(for: .sleep, techniques: [], history: []) == nil)
    }

    @Test(
        "Each stretch of the day points the wheel at its own goal",
        arguments: [
            (hour: 5, goal: TechniqueGoal.energy),
            (hour: 10, goal: .energy),
            (hour: 11, goal: .focus),
            (hour: 16, goal: .focus),
            (hour: 17, goal: .calm),
            (hour: 21, goal: .calm),
            (hour: 22, goal: .sleep),
            (hour: 2, goal: .sleep),
        ]
    )
    func hourPicksTheGoal(hour: Int, goal: TechniqueGoal) {
        #expect(HomeSuggestion.goal(forHour: hour) == goal)
    }
}
