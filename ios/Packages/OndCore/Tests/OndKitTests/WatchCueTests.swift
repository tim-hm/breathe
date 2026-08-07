import OndKit
import Testing

/// The reduction from the phone's intensity curves to the wrist's four taps.
///
/// The roadmap names this as M9's main risk: the coarser vocabulary still has to
/// make an inhale and an exhale feel unmistakably different, and the simulator
/// plays no haptics, so the mapping is worth pinning where it can be.
@Suite("Watch cues")
struct WatchCueTests {
    @Test("A breath's direction survives the reduction")
    func distinguishesTheBreaths() {
        #expect(WatchCue(.inhale) == .rise)
        #expect(WatchCue(.exhale) == .fall)
        #expect(WatchCue(.inhale) != WatchCue(.exhale))
    }

    /// Deliberate, not an oversight: which hold you are in is never in doubt
    /// when you are in it, so both boundaries get the same directionless tap.
    @Test("Both holds share one tap")
    func sharesOneTapAcrossTheHolds() {
        #expect(WatchCue(.holdIn) == .mark)
        #expect(WatchCue(.holdOut) == .mark)
    }

    /// The end-of-session cue is not something a phase can produce — feeling
    /// "finished" at the top of an inhale would be a lie about the plan.
    @Test("No phase is cued as a completion")
    func neverCuesAPhaseAsCompletion() {
        let phases: [PhaseKind] = [.inhale, .holdIn, .exhale, .holdOut]

        #expect(phases.allSatisfy { WatchCue($0) != .complete })
    }
}
