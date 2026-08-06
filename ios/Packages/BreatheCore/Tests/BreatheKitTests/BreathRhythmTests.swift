import BreatheKit
import Foundation
import Testing

/// The rhythm line is the first thing a person reads on the detail screen, and
/// nothing else validates it: a segment at the wrong level draws a hold where
/// the technique breathes, and a vanished stage hides a third of a protocol.
@Suite("Laying a technique out as a rhythm line")
struct BreathRhythmTests {
    private func phase(_ kind: PhaseKind, seconds: Double) -> Phase {
        Phase(kind: kind, duration: .milliseconds(Int(seconds * 1000)))
    }

    private func technique(stages: [Stage]) -> Technique {
        Technique(
            id: "id",
            slug: "slug",
            name: "Name",
            summary: "",
            goal: .calm,
            stages: stages,
            recommendedRounds: 1
        )
    }

    @Test("Box breathing is four equal segments walking full, hold, empty, hold")
    func boxBreathing() {
        let rhythm = BreathRhythm(technique: technique(stages: [
            Stage(
                phases: [
                    phase(.inhale, seconds: 4),
                    phase(.holdIn, seconds: 4),
                    phase(.exhale, seconds: 4),
                    phase(.holdOut, seconds: 4),
                ],
                cycles: 8
            ),
        ]))

        #expect(rhythm.segments.count == 4)
        #expect(rhythm.segments.allSatisfy { abs(($0.end - $0.start) - 0.25) < 1e-9 })
        #expect(rhythm.segments.map(\.endLevel) == [1, 1, 0, 0])
        #expect(rhythm.segments.map(\.startLevel) == [0, 1, 1, 0])
        #expect(!rhythm.segments.contains { $0.dashed })
        #expect(rhythm.bands == [BreathRhythm.Band(start: 0, end: 1, cycles: 8)])
    }

    /// The physiological sigh's second sip must draw as a short top-up, not a
    /// second full climb from empty.
    @Test("Consecutive inhales split the climb by their share of its time")
    func consecutiveInhales() {
        let rhythm = BreathRhythm(technique: technique(stages: [
            Stage(
                phases: [
                    phase(.inhale, seconds: 4),
                    phase(.inhale, seconds: 1),
                    phase(.exhale, seconds: 8),
                ],
                cycles: 3
            ),
        ]))

        let levels = rhythm.segments.map(\.endLevel)
        #expect(abs(levels[0] - 0.8) < 1e-9, "the long inhale covers 4/5 of the climb")
        #expect(levels[1] == 1)
        #expect(levels[2] == 0)
    }

    /// A Wim Hof-style round pairs a two-second cycle with a minute-long
    /// retention; drawn to scale the fast breaths would be a sliver.
    @Test("A brief stage still gets a legible share of the width")
    func briefStageIsWidened() throws {
        let rhythm = BreathRhythm(technique: technique(stages: [
            Stage(
                phases: [phase(.inhale, seconds: 1), phase(.exhale, seconds: 1)],
                cycles: 30
            ),
            Stage(
                phases: [phase(.exhale, seconds: 1), phase(.holdOut, seconds: 59)],
                cycles: 1,
                openEnded: true
            ),
        ]))

        let fast = try #require(rhythm.bands.first)
        #expect(abs((fast.end - fast.start) - BreathRhythm.minimumStageShare) < 1e-9)
        #expect(fast.cycles == 30)

        let slow = try #require(rhythm.bands.last)
        #expect(abs(slow.end - 1) < 1e-9, "the widths still fill the line exactly")
    }

    @Test("Every segment of an open-ended stage is dashed, and only those")
    func openEndedStagesDash() {
        let rhythm = BreathRhythm(technique: technique(stages: [
            Stage(phases: [phase(.inhale, seconds: 2), phase(.exhale, seconds: 2)], cycles: 5),
            Stage(phases: [phase(.holdOut, seconds: 30)], cycles: 1, openEnded: true),
        ]))

        #expect(rhythm.segments.map(\.dashed) == [false, false, true])
    }

    /// The line is continuous by construction — each segment starts where the
    /// one before ended, across stage boundaries included — because a gap or a
    /// jump reads as a breath the technique does not contain.
    @Test("Segments chain without gaps in x or level")
    func segmentsChain() throws {
        let rhythm = BreathRhythm(technique: technique(stages: [
            Stage(phases: [phase(.inhale, seconds: 2), phase(.holdIn, seconds: 1)], cycles: 2),
            Stage(phases: [phase(.exhale, seconds: 4), phase(.holdOut, seconds: 2)], cycles: 1),
        ]))

        for (previous, next) in zip(rhythm.segments, rhythm.segments.dropFirst()) {
            #expect(previous.end == next.start)
            #expect(previous.endLevel == next.startLevel)
        }
        #expect(rhythm.segments.first?.start == 0)
        let last = try #require(rhythm.segments.last)
        #expect(abs(last.end - 1) < 1e-9)
    }
}
