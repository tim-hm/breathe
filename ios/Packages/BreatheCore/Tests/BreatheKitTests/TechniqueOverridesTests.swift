import BreatheKit
import Foundation
import Testing

/// The Advanced dials write these, the catalogue can change underneath them, and
/// nothing between the two revalidates. Applying them is therefore the one place
/// a stale preference could put a duration on the wrong phase or a hold outside
/// its safe range.
@Suite("Applying a person's dialled-in overrides")
struct TechniqueOverridesTests {
    private static let technique = Technique(
        id: "id",
        slug: "extended-exhale",
        name: "Extended Exhale",
        summary: "",
        goal: .sleep,
        stages: [
            Stage(
                phases: [
                    Phase(
                        kind: .inhale,
                        duration: .milliseconds(4000),
                        range: .milliseconds(3000) ... .milliseconds(5000)
                    ),
                    Phase(
                        kind: .exhale,
                        duration: .milliseconds(6000),
                        range: .milliseconds(6000) ... .milliseconds(8000)
                    ),
                ],
                cycles: 12
            ),
        ],
        recommendedRounds: 1
    )

    @Test("No overrides is the curated technique, unchanged")
    func fallsBackToTheCatalogue() {
        #expect(Self.technique.stages(applying: nil) == Self.technique.stages)
        #expect(Self.technique.rounds(applying: nil) == 1)
    }

    @Test("A dialled technique plays what the person chose")
    func appliesTheDial() throws {
        let overrides = TechniqueOverrides(
            phaseDurationsMs: [[5000, 8000]],
            stageCycles: [20],
            rounds: 1
        )

        let stage = try #require(Self.technique.stages(applying: overrides).first)

        #expect(stage.phases.map(\.duration) == [.milliseconds(5000), .milliseconds(8000)])
        #expect(stage.cycles == 20)
        #expect(
            stage.phases[0].range == Self.technique.stages[0].phases[0].range,
            "a dial moves the duration, never the range it moves within"
        )
    }

    /// The evidence-based range is the product's safety story. A stored value
    /// from before it was tightened must land inside the new one, not outside.
    @Test("A dial is clamped into the range the catalogue seeded")
    func clampsIntoTheSeededRange() throws {
        let overrides = TechniqueOverrides(
            phaseDurationsMs: [[99999, 1]],
            stageCycles: [9999],
            rounds: 99
        )

        let stage = try #require(Self.technique.stages(applying: overrides).first)

        #expect(stage.phases.map(\.duration) == [.milliseconds(5000), .milliseconds(6000)])
        #expect(stage.cycles == TechniqueOverrides.cycleRange.upperBound)
        #expect(Self.technique.rounds(applying: overrides) == TechniqueOverrides.roundRange
            .upperBound)
    }

    /// The one case parallel arrays exist to make detectable: a technique that
    /// gained a phase since the preference was written. There is no way to know
    /// which stored duration belonged to which new phase, so the whole
    /// preference goes rather than half of it landing on the wrong beat.
    @Test("Overrides that no longer fit the technique are dropped whole")
    func dropsOverridesThatNoLongerFit() {
        let stale = TechniqueOverrides(
            phaseDurationsMs: [[5000]],
            stageCycles: [20],
            rounds: 1
        )

        #expect(Self.technique.stages(applying: stale) == Self.technique.stages)
        #expect(Self.technique.rounds(applying: stale) == 1)
    }

    @Test("The curated overrides describe the technique as seeded")
    func curatedOverridesRoundTrip() {
        let curated = Self.technique.curatedOverrides

        #expect(curated.phaseDurationsMs == [[4000, 6000]])
        #expect(curated.stageCycles == [12])
        #expect(curated.rounds == 1)
        #expect(Self.technique.stages(applying: curated) == Self.technique.stages)
    }
}
