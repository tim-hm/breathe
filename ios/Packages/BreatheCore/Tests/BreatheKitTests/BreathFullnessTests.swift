import BreatheKit
import Foundation
import Testing

/// The number both breath guides are drawn from.
///
/// Worth pinning because two apps render it — an orb in the hand, a disc on the
/// wrist — and a drift between them would be a technique that visibly breathes
/// differently on the two devices doing it at the same time.
@Suite("Breath fullness")
struct BreathFullnessTests {
    private func timeline(_ kind: PhaseKind) -> SessionTimeline {
        SessionTimeline(
            stages: [Stage(phases: [Phase(kind: kind, duration: .seconds(4))], cycles: 1)],
            rounds: 1
        )
    }

    private func beat(_ kind: PhaseKind) throws -> SessionTimeline.Beat {
        try #require(timeline(kind).beats.first)
    }

    /// The easing is arithmetic on `Double`, so an exhale's floor arrives as
    /// 0.44999999999999996 rather than 0.45. That is a rounding artefact and not
    /// a difference anything renders, so the comparisons carry a tolerance.
    private func isClose(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 0.000001
    }

    @Test("An inhale rises from empty to full")
    func fillsOnAnInhale() throws {
        let inhale = try beat(.inhale)

        #expect(isClose(inhale.lungFullness(at: .zero), SessionTimeline.Beat.emptyLungs))
        #expect(isClose(inhale.lungFullness(at: .seconds(4)), 1))
        #expect(inhale.lungFullness(at: .seconds(1)) < inhale.lungFullness(at: .seconds(3)))
    }

    /// Mirrored rather than merely decreasing: the same easing run backwards, so
    /// the top of an inhale and the top of an exhale are the same shape.
    @Test("An exhale mirrors the inhale")
    func mirrorsOnAnExhale() throws {
        let inhale = try beat(.inhale)
        let exhale = try beat(.exhale)

        #expect(isClose(exhale.lungFullness(at: .zero), 1))
        #expect(isClose(exhale.lungFullness(at: .seconds(4)), SessionTimeline.Beat.emptyLungs))

        for offset in [1, 2, 3] {
            let at = Duration.seconds(offset)
            let sum = inhale.lungFullness(at: at) + exhale.lungFullness(at: at)
            #expect(isClose(sum, 1 + SessionTimeline.Beat.emptyLungs))
        }
    }

    /// Nothing scales during a hold, which is why both guides shift colour
    /// instead — with the disc frozen, that is the only marker of the change.
    @Test("A hold holds still, at whichever end it is held")
    func holdsStill() throws {
        let holdIn = try beat(.holdIn)
        let holdOut = try beat(.holdOut)

        for offset in [0, 2, 4] {
            #expect(isClose(holdIn.lungFullness(at: .seconds(offset)), 1))
            #expect(
                isClose(holdOut.lungFullness(at: .seconds(offset)), SessionTimeline.Beat.emptyLungs)
            )
        }
    }

    /// The last second of a phase is still a second of it, so nothing ever
    /// counts down to zero on screen.
    @Test("Seconds remaining count down and floor at one")
    func countsWholeSecondsDown() throws {
        let inhale = try beat(.inhale)

        #expect(inhale.secondsRemaining(at: .zero) == 4)
        #expect(inhale.secondsRemaining(at: .milliseconds(1500)) == 3)
        #expect(inhale.secondsRemaining(at: .seconds(4)) == 1)
    }

    @Test("Only the holds are holds")
    func namesTheHolds() {
        #expect(PhaseKind.holdIn.isHold)
        #expect(PhaseKind.holdOut.isHold)
        #expect(PhaseKind.inhale.isHold == false)
        #expect(PhaseKind.exhale.isHold == false)
    }
}
