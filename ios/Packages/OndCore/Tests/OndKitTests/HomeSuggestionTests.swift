import Foundation
import OndKit
import Testing

/// The home screen's rules are trivial to eyeball and easy to get quietly
/// wrong: an off-by-one hour boundary points the aim at bellows breath at
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

    @Test("Home offers what this person last used towards the goal")
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

    /// Home only offers goals the catalogue can serve, but a technique
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

    /// The home screen's aims, the techniques list's sections, and anything
    /// else built from a catalogue read this one order. A catalogue that came
    /// back sorted differently must not move sleep out from under a thumb that
    /// has learned where it is.
    @Test("Present goals come back in the enum's order, not the catalogue's")
    func presentGoalsFollowTheEnum() {
        let shuffled = [
            technique(slug: "478", goal: .sleep),
            technique(slug: "bellows", goal: .energy),
            technique(slug: "box", goal: .calm),
        ]

        #expect(TechniqueGoal.present(in: shuffled) == [.calm, .sleep, .energy])
        #expect(TechniqueGoal.present(in: []).isEmpty)
    }

    @Test(
        "Each stretch of the day points the aim at its own goal",
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

    @Test("A swipe past the last aim wraps to the first, and back past the first to the last")
    func cyclingWrapsAtBothEnds() {
        let goals: [TechniqueGoal] = [.calm, .sleep, .energy]

        #expect(TechniqueGoal.energy.next(in: goals) == .calm)
        #expect(TechniqueGoal.calm.previous(in: goals) == .energy)
    }

    @Test("Cycling steps through the list's order")
    func cyclingFollowsTheOrder() {
        let goals: [TechniqueGoal] = [.calm, .sleep, .energy]

        #expect(TechniqueGoal.calm.next(in: goals) == .sleep)
        #expect(TechniqueGoal.sleep.previous(in: goals) == .calm)
    }

    /// `lastGoal` can restore an aim the catalogue no longer serves; a swipe
    /// from there starts over at the front — the same answer settling gives.
    @Test("A restored aim the catalogue no longer serves cycles from the first")
    func absentGoalCyclesFromTheFront() {
        let goals: [TechniqueGoal] = [.calm, .sleep]

        #expect(TechniqueGoal.focus.next(in: goals) == .calm)
        #expect(TechniqueGoal.focus.previous(in: goals) == .calm)
    }

    @Test("One aim cycles to itself; none cycles to nothing")
    func degenerateListsCycleSafely() {
        #expect(TechniqueGoal.calm.next(in: [.calm]) == .calm)
        #expect(TechniqueGoal.calm.previous(in: [.calm]) == .calm)
        #expect(TechniqueGoal.calm.next(in: []) == nil)
        #expect(TechniqueGoal.calm.previous(in: []) == nil)
    }
}
