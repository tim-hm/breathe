import BreatheKit
import Foundation
import Testing

/// The hints are pinned to a slug while the catalogue lives on a server, so
/// the shape check is the whole safety story: it is what keeps "left nostril"
/// off the wrong breath after a reseed this build never saw.
@Suite("Pinning phase hints to a technique")
struct PhaseHintsTests {
    private func alternateNostril(kinds: [PhaseKind]) -> Technique {
        Technique(
            id: "id",
            slug: "alternate-nostril",
            name: "Alternate-Nostril Breathing",
            summary: "",
            goal: .focus,
            stages: [
                Stage(
                    phases: kinds.map { Phase(kind: $0, duration: .seconds(4)) },
                    cycles: 9
                ),
            ],
            recommendedRounds: 1
        )
    }

    @Test("Alternate-nostril alternates left, right, right, left")
    func alternateNostrilHints() throws {
        let technique = alternateNostril(kinds: [.inhale, .exhale, .inhale, .exhale])

        let hints = try #require(PhaseHints.hints(for: technique))

        #expect(hints == [["Left nostril", "Right nostril", "Right nostril", "Left nostril"]])
    }

    @Test("Dialling durations does not shake the hints loose")
    func dialledTechniqueKeepsHints() {
        let technique = alternateNostril(kinds: [.inhale, .exhale, .inhale, .exhale])
        let dialled = technique.dialled(with: technique.curatedOverrides)

        #expect(PhaseHints.hints(for: dialled) != nil)
    }

    @Test("A reshaped technique drops its hints rather than misplacing them")
    func reshapedTechniqueDropsHints() {
        let reordered = alternateNostril(kinds: [.inhale, .holdIn, .exhale, .holdOut])
        let regrown = alternateNostril(kinds: [.inhale, .exhale])

        #expect(PhaseHints.hints(for: reordered) == nil, "same length, different kinds")
        #expect(PhaseHints.hints(for: regrown) == nil)
    }

    @Test("A technique with no entry has no hints")
    func unknownSlug() {
        let box = Technique(
            id: "box",
            slug: "box-breathing",
            name: "Box Breathing",
            summary: "",
            goal: .calm,
            stages: [
                Stage(phases: [Phase(kind: .inhale, duration: .seconds(4))], cycles: 8),
            ],
            recommendedRounds: 1
        )

        #expect(PhaseHints.hints(for: box) == nil)
    }
}
