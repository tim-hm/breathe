import Foundation
import OndKit
import Testing

/// The curve discreet mode is paced by.
///
/// None of this can say whether 3-5-8-13 helps somebody through a meeting —
/// only wearing it can. What it can pin is everything downstream of the four
/// numbers: where the bursts land, that no two gaps are the same length, and
/// that the whole thing still covers the half hour it promises. Change the
/// numbers and these should fail, which is the point of them.
@Suite("Discreet cadence")
struct DiscreetCadenceTests {
    /// The schedule the issue decided, restated as the times it produces. Read
    /// this as the assertion that `burstStarts` derives the curve correctly, not
    /// as a second copy of it.
    @Test("Bursts land at 0, 3, 8, 16 and 29 minutes")
    func placesTheBursts() {
        #expect(DiscreetCadence.burstStarts == [
            .seconds(0),
            .seconds(3 * 60),
            .seconds(8 * 60),
            .seconds(16 * 60),
            .seconds(29 * 60),
        ])
    }

    /// The mechanism, not a refinement of it: a fixed interval habituates, and
    /// a cue nobody notices any more is the failure this mode was designed
    /// around.
    @Test("Every gap is longer than the one before it")
    func widensEveryGap() {
        let gaps = DiscreetCadence.gaps

        #expect(gaps.count > 1)
        #expect(zip(gaps, gaps.dropFirst()).allSatisfy { $0 < $1 })
    }

    /// A meeting is the unit this is measured in, so the session has to outlast
    /// half an hour rather than nearly reach it — the closing burst is what
    /// carries it over.
    @Test("A discreet session covers the half hour it promises")
    func coversTheHalfHour() {
        let duration = DiscreetCadence.duration(of: SeededCatalogue.technique("coherent-breathing"))

        #expect(duration >= .seconds(30 * 60))
        #expect(duration < .seconds(31 * 60))
    }

    /// Six breaths at the technique's own pace rather than a pace of this
    /// mode's own. Discreet mode adds nothing to the catalogue: it is a way of
    /// delivering what is already there.
    @Test("A burst is six breaths at the technique's own pace")
    func pacesTheBurstByTheTechnique() {
        let technique = SeededCatalogue.technique("coherent-breathing")
        let burst = DiscreetCadence.burst(of: technique)
        let cycle = technique.stages.first?.cycleDuration ?? .zero

        #expect(burst.breathsCompleted(at: burst.totalDuration) == DiscreetCadence.cyclesPerBurst)
        #expect(burst.totalDuration == cycle * DiscreetCadence.cyclesPerBurst)
    }
}
