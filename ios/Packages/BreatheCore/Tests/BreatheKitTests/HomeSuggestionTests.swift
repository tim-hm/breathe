import BreatheKit
import Foundation
import Testing

/// The hero card's rules are trivial to eyeball and easy to get quietly wrong:
/// an off-by-one hour boundary suggests bellows breath at bedtime, and a
/// deleted technique's slug in the history must not sink the card entirely.
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

    @Test("An empty catalogue suggests nothing")
    func emptyCatalogue() {
        #expect(HomeSuggestion
            .make(techniques: [], history: [session(slug: "box")], hour: 12) == nil)
    }

    @Test("The most recent session wins over the time of day")
    func historyWins() {
        let suggestion = HomeSuggestion.make(
            techniques: catalogue,
            history: [session(slug: "box"), session(slug: "478")],
            hour: 12
        )

        #expect(suggestion == .beginAgain(technique(slug: "478", goal: .sleep)))
        #expect(suggestion?.prompt == "Begin again")
    }

    @Test("History whose technique left the catalogue falls back to the hour")
    func staleHistoryFallsThrough() {
        let suggestion = HomeSuggestion.make(
            techniques: catalogue,
            history: [session(slug: "retired-technique")],
            hour: 12
        )

        #expect(suggestion?.technique.goal == .focus)
    }

    @Test(
        "Each stretch of the day reaches for its own goal",
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
        let suggestion = HomeSuggestion.make(techniques: catalogue, history: [], hour: hour)

        #expect(suggestion?.technique.goal == goal)
    }

    @Test("A catalogue without the hour's goal still suggests something")
    func missingGoalStillSuggests() {
        let sleepless = [technique(slug: "box", goal: .calm)]

        let suggestion = HomeSuggestion.make(techniques: sleepless, history: [], hour: 23)

        #expect(suggestion?.technique.slug == "box")
    }
}
