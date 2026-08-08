/// Whatever turns a phase boundary into something you can feel or hear.
///
/// The player drives this rather than owning it: `CHHapticEngine` and
/// `AVAudioPlayer` are UIKit-era, iOS-only APIs, and the watch app has a
/// different haptic vocabulary entirely. Keeping the protocol in `OndKit` and the
/// implementations in the app targets is what lets the session engine be the same
/// code on both, and lets it run on the host under test with no cues at all.
@MainActor
public protocol SessionCueing {
    /// Whether these cues keep reaching the person with the app backgrounded and
    /// the screen off.
    ///
    /// What decides whether leaving the app is an interruption or the posture the
    /// technique is done in. Eyes shut with the phone face down is the second, so
    /// a channel that survives the departure wants the session left running — and
    /// one that goes quiet has to say so, or the person breathes to nothing.
    var playsInBackground: Bool { get }

    /// Called before the first beat. Engine warm-up belongs here, not on the
    /// first boundary, where the latency would land inside the cue.
    func prepare()

    /// Bracket a pause, and the resume that undoes it.
    ///
    /// Distinct from `prepare()` and `stop()`, which bracket the whole session:
    /// the engines stay warm across these, because a resume lands on a phase
    /// boundary and re-warming one there would put the latency inside the cue.
    /// What changes is only whether a paused session still has a claim on the
    /// runtime that keeps the app alive — left playing, it would hold the phone
    /// awake for as long as somebody's forgotten pause lasts.
    func pause()
    func resume()

    func play(_ beat: SessionTimeline.Beat)
    /// The session reached its end, as opposed to being ended.
    func playCompletion()
    func stop()
}
