import BreatheAPI
@testable import BreatheKit
import Foundation
import Testing

@Suite("Decoding proto techniques into domain types")
struct TechniqueDecodingTests {
    private func protoTechnique(
        goal: Breathe_V1_TechniqueGoal = .calm,
        phases: [Breathe_V1_Phase] = [phase(.inhale, 4000), phase(.exhale, 4000)]
    ) -> Breathe_V1_Technique {
        var technique = Breathe_V1_Technique()
        technique.id = "id"
        technique.slug = "box-breathing"
        technique.name = "Box Breathing"
        technique.summary = "Four equal counts."
        technique.goal = goal
        technique.phases = phases
        return technique
    }

    private static func phase(_ kind: Breathe_V1_PhaseKind, _ ms: UInt32) -> Breathe_V1_Phase {
        var phase = Breathe_V1_Phase()
        phase.kind = kind
        phase.durationMs = ms
        return phase
    }

    @Test("A well-formed technique decodes with its cycle intact")
    func decodesAWellFormedTechnique() throws {
        let technique = try Technique(proto: protoTechnique())

        #expect(technique.slug == "box-breathing")
        #expect(technique.goal == .calm)
        #expect(technique.phases.count == 2)
        #expect(technique.cycleDuration == .milliseconds(8000))
    }

    /// The proto zero value is reachable from any server, including one running
    /// a newer contract. Decoding it as a real goal would put a technique in the
    /// wrong section of the catalogue with nothing to indicate it.
    @Test("An unspecified goal is rejected rather than defaulted")
    func rejectsAnUnspecifiedGoal() {
        #expect(throws: TechniqueRepositoryError.self) {
            try Technique(proto: protoTechnique(goal: .unspecified))
        }
    }

    /// A phase-less technique would leave the player with an empty loop and no
    /// segment to advance to.
    @Test("A technique with no phases is rejected")
    func rejectsATechniqueWithNoPhases() {
        #expect(throws: TechniqueRepositoryError.self) {
            try Technique(proto: protoTechnique(phases: []))
        }
    }

    @Test("Every domain goal has a display title")
    func everyGoalHasATitle() {
        for goal in TechniqueGoal.allCases {
            #expect(!goal.title.isEmpty)
        }
    }
}
