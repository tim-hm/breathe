import BreatheKit
import Foundation
import Testing

@Suite("Laying a technique out on a session's time axis")
struct SessionTimelineTests {
    /// 4-4-4-4, the shape every boundary assertion below is easy to check by
    /// hand against.
    private static let boxStage = Stage(
        phases: [
            Phase(kind: .inhale, duration: .milliseconds(4000)),
            Phase(kind: .holdIn, duration: .milliseconds(4000)),
            Phase(kind: .exhale, duration: .milliseconds(4000)),
            Phase(kind: .holdOut, duration: .milliseconds(4000)),
        ],
        cycles: 8
    )

    /// Two inhales, one of them sub-second. The reason phase durations are
    /// milliseconds at all, and the case any integer-seconds shortcut breaks on.
    private static let sighStage = Stage(
        phases: [
            Phase(kind: .inhale, duration: .milliseconds(1500)),
            Phase(kind: .inhale, duration: .milliseconds(700)),
            Phase(kind: .exhale, duration: .milliseconds(5000)),
        ],
        cycles: 3
    )

    /// The shape the stage model exists for, scaled down so the arithmetic stays
    /// checkable by hand: three fast breaths (6s), an open-ended hold seeded at
    /// a typical 60s, then a 22s recovery. One round is 88 seconds.
    private static let staged = [
        Stage(
            phases: [
                Phase(kind: .inhale, duration: .milliseconds(1000)),
                Phase(kind: .exhale, duration: .milliseconds(1000)),
            ],
            cycles: 3
        ),
        Stage(
            phases: [Phase(kind: .holdOut, duration: .milliseconds(60000))],
            cycles: 1,
            openEnded: true
        ),
        Stage(
            phases: [
                Phase(kind: .inhale, duration: .milliseconds(3000)),
                Phase(kind: .holdIn, duration: .milliseconds(15000)),
                Phase(kind: .exhale, duration: .milliseconds(4000)),
            ],
            cycles: 1
        ),
    ]

    @Test("A session is its cycle, repeated")
    func laysOutEveryCycle() {
        let timeline = SessionTimeline(stages: [Self.boxStage], rounds: 1)

        #expect(timeline.beats.count == 32)
        #expect(timeline.totalCycles == 8)
        #expect(timeline.roundDuration == .milliseconds(128_000))
        #expect(timeline.totalDuration == .milliseconds(128_000))
        #expect(timeline.beats.last?.cycle == 7)
        #expect(timeline.beats.last?.end == timeline.totalDuration)
    }

    /// The flattening is rounds × stages × cycles × phases, and every factor is
    /// load-bearing: drop the rounds and a Wim Hof-style session is a third of
    /// its length, flatten the stages in the wrong order and the retention lands
    /// before the breaths that make it possible.
    @Test("Stages flatten into rounds of stages of cycles")
    func flattensStagesIntoRounds() throws {
        let timeline = SessionTimeline(stages: Self.staged, rounds: 2)

        // Per round: 3 cycles × 2 phases, one hold, three recovery phases.
        #expect(timeline.beats.count == 20)
        #expect(timeline.totalCycles == 10)
        #expect(timeline.roundDuration == .milliseconds(88000))
        #expect(timeline.totalDuration == .milliseconds(176_000))

        let opening = try #require(timeline.beats.first)
        #expect(opening.round == 0)
        #expect(opening.stage == 0)
        #expect(opening.cycle == 0)

        let closing = try #require(timeline.beats.last)
        #expect(closing.round == 1)
        #expect(closing.stage == 2)
        #expect(closing.kind == .exhale)
    }

    /// A beat covers `[start, end)`. Landing exactly on a boundary must give the
    /// arriving phase, or a cue loop that wakes on time cues the phase that has
    /// just finished — and every phase would be announced one beat late. The
    /// seams between stages and between rounds are where an off-by-one hides.
    @Test("A boundary belongs to the phase it starts, across stage seams")
    func resolvesPhasesAtTheirBoundaries() throws {
        let timeline = SessionTimeline(stages: Self.staged, rounds: 2)

        #expect(timeline.beat(at: .zero)?.kind == .inhale)
        #expect(timeline.beat(at: .milliseconds(5999))?.stage == 0)

        // Into the retention, and still in it a second before it nominally ends.
        let retention = try #require(timeline.beat(at: .milliseconds(6000)))
        #expect(retention.stage == 1)
        #expect(retention.kind == .holdOut)
        #expect(retention.isOpenEnded)
        #expect(timeline.beat(at: .milliseconds(65999))?.stage == 1)

        // Out of it and into the recovery breath.
        let recovery = try #require(timeline.beat(at: .milliseconds(66000)))
        #expect(recovery.stage == 2)
        #expect(recovery.kind == .inhale)
        #expect(!recovery.isOpenEnded)

        // The first beat of the second round, not the last of the first.
        let secondRound = try #require(timeline.beat(at: .milliseconds(88000)))
        #expect(secondRound.round == 1)
        #expect(secondRound.stage == 0)
        #expect(secondRound.cycle == 0)
        #expect(timeline.beat(at: .milliseconds(87999))?.round == 0)
    }

    /// The end of the last beat is the end of the session — the moment the
    /// player stops rather than one more frame of the closing hold.
    @Test("The session's end resolves to no phase at all")
    func endsRatherThanRepeating() {
        let timeline = SessionTimeline(stages: [Self.boxStage], rounds: 1)

        #expect(timeline.beat(at: .milliseconds(127_999)) != nil)
        #expect(timeline.beat(at: timeline.totalDuration) == nil)
        #expect(timeline.beat(at: .milliseconds(999_999)) == nil)
    }

    @Test("Sub-second phases resolve as precisely as they are authored")
    func resolvesSubSecondPhases() throws {
        let timeline = SessionTimeline(stages: [Self.sighStage], rounds: 1)

        // The second sip of air: 1500ms in, 700ms long.
        #expect(timeline.beat(at: .milliseconds(1499))?.id == 0)
        #expect(timeline.beat(at: .milliseconds(1500))?.id == 1)
        #expect(timeline.beat(at: .milliseconds(2199))?.id == 1)
        #expect(timeline.beat(at: .milliseconds(2200))?.kind == .exhale)

        let sip = try #require(timeline.beat(at: .milliseconds(1850)))
        #expect(sip.fraction(at: .milliseconds(1850)) == 0.5)
    }

    /// What the summary counts, and what someone who stopped early is told. The
    /// staged case is the one that matters: stages of different lengths make
    /// `elapsed / cycleDuration` wrong, because there is no such thing as *the*
    /// cycle duration once a 2-second breath and a 60-second hold are both one.
    @Test("Only whole cycles count as completed, across uneven stages")
    func countsWholeCyclesOnly() {
        let timeline = SessionTimeline(stages: Self.staged, rounds: 2)

        #expect(timeline.cyclesCompleted(at: .zero) == 0)
        #expect(timeline.cyclesCompleted(at: .milliseconds(1999)) == 0)
        #expect(timeline.cyclesCompleted(at: .milliseconds(2000)) == 1)
        // The three fast breaths, then the retention, then the recovery.
        #expect(timeline.cyclesCompleted(at: .milliseconds(6000)) == 3)
        #expect(timeline.cyclesCompleted(at: .milliseconds(66000)) == 4)
        #expect(timeline.cyclesCompleted(at: .milliseconds(88000)) == 5)
        #expect(timeline.cyclesCompleted(at: timeline.totalDuration) == 10)
        // A clock that overshoots the last boundary cannot report an eleventh.
        #expect(timeline.cyclesCompleted(at: .milliseconds(999_999)) == 10)
    }

    /// Rounds are the unit a staged protocol is counted in — three rounds is the
    /// thing someone says they did, not ninety-six cycles.
    @Test("Rounds are counted whole, like cycles")
    func countsWholeRoundsOnly() {
        let timeline = SessionTimeline(stages: Self.staged, rounds: 2)

        #expect(timeline.roundsCompleted(at: .milliseconds(87999)) == 0)
        #expect(timeline.roundsCompleted(at: .milliseconds(88000)) == 1)
        #expect(timeline.roundsCompleted(at: timeline.totalDuration) == 2)
        #expect(timeline.roundsCompleted(at: .milliseconds(999_999)) == 2)
    }

    /// Breaths are counted per inhale, not per cycle — the physiological sigh
    /// takes two, and both are breaths the person drew.
    @Test("Breaths are counted per inhale")
    func countsInhalesRatherThanCycles() {
        let timeline = SessionTimeline(stages: [Self.sighStage], rounds: 1)

        #expect(timeline.breathsCompleted(at: .zero) == 0)
        #expect(timeline.breathsCompleted(at: .milliseconds(1500)) == 1)
        #expect(timeline.breathsCompleted(at: .milliseconds(2200)) == 2)
        #expect(timeline.breathsCompleted(at: timeline.totalDuration) == 6)

        // Four per round in the staged shape: three fast, one recovery.
        let staged = SessionTimeline(stages: Self.staged, rounds: 2)
        #expect(staged.breathsCompleted(at: staged.totalDuration) == 8)
    }

    @Test("A phase's fraction is clamped to its own span")
    func clampsFractionToThePhase() throws {
        let timeline = SessionTimeline(stages: [Self.boxStage], rounds: 1)
        let inhale = try #require(timeline.beat(at: .zero))

        #expect(inhale.fraction(at: .zero) == 0)
        #expect(inhale.fraction(at: .milliseconds(2000)) == 0.5)
        #expect(inhale.fraction(at: .milliseconds(4000)) == 1)
        #expect(inhale.fraction(at: .milliseconds(9000)) == 1)
    }

    /// A stepper bug should not open a full-screen player onto an
    /// already-finished session, and is not worth trapping over either.
    @Test("A session is never shorter than one round")
    func floorsTheRoundCount() {
        #expect(SessionTimeline(stages: [Self.boxStage], rounds: 0).rounds == 1)
        #expect(SessionTimeline(stages: [Self.boxStage], rounds: -3).beats.count == 32)
    }

    @Test("A technique's own recommendation is the default length")
    func defaultsToTheCuratedLength() {
        let technique = Technique(
            id: "id",
            slug: "wim-hof-rounds",
            name: "Wim Hof-style Rounds",
            summary: "",
            goal: .energy,
            stages: Self.staged,
            recommendedRounds: 3
        )

        #expect(SessionTimeline(technique: technique).rounds == 3)
        #expect(SessionTimeline(technique: technique, rounds: 1).rounds == 1)
    }
}
