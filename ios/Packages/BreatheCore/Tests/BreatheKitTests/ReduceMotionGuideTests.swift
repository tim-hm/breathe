import BreatheKit
import Foundation
import Testing

/// The number both breath guides fall back to under Reduce Motion.
///
/// With scaling suppressed, the phone's `BreathVisual` and the watch's
/// `BreathRing` render the current phase as a ring trimmed by
/// `Beat.fraction(at:)`. Neither view can be tested directly — both live in app
/// targets, and every Swift suite runs on the host out of `BreatheCore` — so
/// what is pinned here is the one property that makes those renderings work:
/// through a hold, the phase fill and the lung fullness disagree, and only the
/// first of them is renderable as guidance.
@Suite("Reduce Motion breath guide")
struct ReduceMotionGuideTests {
    @Test(
        "A hold moves the phase fill while lung fullness stands still",
        arguments: [PhaseKind.holdIn, .holdOut]
    )
    func aHoldStillReadsAsProgress(_ kind: PhaseKind) throws {
        let timeline = SessionTimeline(
            stages: [Stage(phases: [Phase(kind: kind, duration: .seconds(4))], cycles: 1)],
            rounds: 1
        )
        let beat = try #require(timeline.beats.first)

        #expect(beat.lungFullness(at: .zero) == beat.lungFullness(at: .seconds(3)))
        #expect(beat.fraction(at: .zero) < beat.fraction(at: .seconds(3)))
    }
}
