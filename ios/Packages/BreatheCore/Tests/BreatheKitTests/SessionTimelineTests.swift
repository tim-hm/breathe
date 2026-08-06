import BreatheKit
import Foundation
import Testing

@Suite("Laying a technique out on a session's time axis")
struct SessionTimelineTests {
    /// 4-4-4-4, the shape every boundary assertion below is easy to check by
    /// hand against.
    private static let boxCycle = [
        Phase(kind: .inhale, duration: .milliseconds(4000)),
        Phase(kind: .holdIn, duration: .milliseconds(4000)),
        Phase(kind: .exhale, duration: .milliseconds(4000)),
        Phase(kind: .holdOut, duration: .milliseconds(4000)),
    ]

    /// Two inhales, one of them sub-second. The reason phase durations are
    /// milliseconds at all, and the case any integer-seconds shortcut breaks on.
    private static let sighCycle = [
        Phase(kind: .inhale, duration: .milliseconds(1500)),
        Phase(kind: .inhale, duration: .milliseconds(700)),
        Phase(kind: .exhale, duration: .milliseconds(5000)),
    ]

    @Test("A session is its cycle, repeated")
    func laysOutEveryCycle() {
        let timeline = SessionTimeline(phases: Self.boxCycle, cycles: 8)

        #expect(timeline.beats.count == 32)
        #expect(timeline.cycleDuration == .milliseconds(16000))
        #expect(timeline.totalDuration == .milliseconds(128_000))
        #expect(timeline.beats.last?.cycle == 7)
        #expect(timeline.beats.last?.end == timeline.totalDuration)
    }

    /// A beat covers `[start, end)`. Landing exactly on a boundary must give the
    /// arriving phase, or a cue loop that wakes on time cues the phase that has
    /// just finished — and every phase would be announced one beat late.
    @Test("A boundary belongs to the phase it starts")
    func resolvesPhasesAtTheirBoundaries() {
        let timeline = SessionTimeline(phases: Self.boxCycle, cycles: 2)

        #expect(timeline.beat(at: .zero)?.kind == .inhale)
        #expect(timeline.beat(at: .milliseconds(3999))?.kind == .inhale)
        #expect(timeline.beat(at: .milliseconds(4000))?.kind == .holdIn)
        #expect(timeline.beat(at: .milliseconds(15999))?.kind == .holdOut)

        // The first beat of the second cycle, not the last of the first.
        let secondCycleStart = timeline.beat(at: .milliseconds(16000))
        #expect(secondCycleStart?.kind == .inhale)
        #expect(secondCycleStart?.cycle == 1)
    }

    /// The end of the last beat is the end of the session — the moment the
    /// player stops rather than one more frame of the closing hold.
    @Test("The session's end resolves to no phase at all")
    func endsRatherThanRepeating() {
        let timeline = SessionTimeline(phases: Self.boxCycle, cycles: 1)

        #expect(timeline.beat(at: .milliseconds(15999)) != nil)
        #expect(timeline.beat(at: timeline.totalDuration) == nil)
        #expect(timeline.beat(at: .milliseconds(99999)) == nil)
    }

    @Test("Sub-second phases resolve as precisely as they are authored")
    func resolvesSubSecondPhases() throws {
        let timeline = SessionTimeline(phases: Self.sighCycle, cycles: 3)

        // The second sip of air: 1500ms in, 700ms long.
        #expect(timeline.beat(at: .milliseconds(1499))?.id == 0)
        #expect(timeline.beat(at: .milliseconds(1500))?.id == 1)
        #expect(timeline.beat(at: .milliseconds(2199))?.id == 1)
        #expect(timeline.beat(at: .milliseconds(2200))?.kind == .exhale)

        let sip = try #require(timeline.beat(at: .milliseconds(1850)))
        #expect(sip.fraction(at: .milliseconds(1850)) == 0.5)
    }

    /// What the summary counts, and what someone who stopped early is told.
    @Test("Only whole cycles count as completed")
    func countsWholeCyclesOnly() {
        let timeline = SessionTimeline(phases: Self.boxCycle, cycles: 8)

        #expect(timeline.cyclesCompleted(at: .zero) == 0)
        #expect(timeline.cyclesCompleted(at: .milliseconds(15999)) == 0)
        #expect(timeline.cyclesCompleted(at: .milliseconds(16000)) == 1)
        #expect(timeline.cyclesCompleted(at: .milliseconds(20000)) == 1)
        #expect(timeline.cyclesCompleted(at: timeline.totalDuration) == 8)
        // A clock that overshoots the last boundary cannot report a ninth cycle.
        #expect(timeline.cyclesCompleted(at: .milliseconds(999_999)) == 8)
    }

    /// Breaths are counted per inhale, not per cycle — the physiological sigh
    /// takes two, and both are breaths the person drew.
    @Test("Breaths are counted per inhale")
    func countsInhalesRatherThanCycles() {
        let timeline = SessionTimeline(phases: Self.sighCycle, cycles: 3)

        #expect(timeline.breathsCompleted(at: .zero) == 0)
        #expect(timeline.breathsCompleted(at: .milliseconds(1500)) == 1)
        #expect(timeline.breathsCompleted(at: .milliseconds(2200)) == 2)
        #expect(timeline.breathsCompleted(at: timeline.totalDuration) == 6)
    }

    @Test("A phase's fraction is clamped to its own span")
    func clampsFractionToThePhase() throws {
        let timeline = SessionTimeline(phases: Self.boxCycle, cycles: 1)
        let inhale = try #require(timeline.beat(at: .zero))

        #expect(inhale.fraction(at: .zero) == 0)
        #expect(inhale.fraction(at: .milliseconds(2000)) == 0.5)
        #expect(inhale.fraction(at: .milliseconds(4000)) == 1)
        #expect(inhale.fraction(at: .milliseconds(9000)) == 1)
    }

    /// A stepper bug should not open a full-screen player onto an
    /// already-finished session, and is not worth trapping over either.
    @Test("A session is never shorter than one cycle")
    func floorsTheCycleCount() {
        #expect(SessionTimeline(phases: Self.boxCycle, cycles: 0).cycles == 1)
        #expect(SessionTimeline(phases: Self.boxCycle, cycles: -3).beats.count == 4)
    }

    @Test("A technique's own recommendation is the default length")
    func defaultsToTheCuratedLength() {
        let technique = Technique(
            id: "id",
            slug: "box-breathing",
            name: "Box Breathing",
            summary: "",
            goal: .calm,
            phases: Self.boxCycle,
            recommendedCycles: 8
        )

        #expect(SessionTimeline(technique: technique).cycles == 8)
        #expect(SessionTimeline(technique: technique, cycles: 2).cycles == 2)
    }
}
