import OndKit

/// The app's implementation of `SessionCueing`: whichever cue channels the
/// person has switched on, driven from the one session loop.
///
/// The mode is resolved once, when the session starts, into "which controllers
/// exist" — so every call site downstream is a nil-check rather than a switch,
/// and a mode change mid-session cannot leave the audio session half-configured.
@MainActor
final class SessionCues: SessionCueing {
    private let haptics: HapticController?
    private let audio: SessionAudioPlayer?

    init(mode: SessionCueMode, strength: HapticStrength) {
        haptics = mode.playsHaptics ? HapticController(strength: strength) : nil
        audio = mode.playsAudio ? SessionAudioPlayer() : nil
    }

    /// Sound is the whole of the answer, and settled rather than provisional.
    ///
    /// The runtime a backgrounded session lives on is granted for playing audio,
    /// so a session with sound switched off has no honest claim to it — and it is
    /// the claim, not the code, that App Review reads.
    ///
    /// Haptics cannot take the slack up, and the device answered that question on
    /// 2026-08-08: under a locked screen the tones kept playing and the taps
    /// never fired once. iOS withholds haptics from a locked device however much
    /// runtime the app holds, so there is no arrangement in which this is true
    /// without sound and no version of it left to try.
    ///
    /// What that settles is the fallback. A silent session stops when the person
    /// leaves and is told that it stopped — `SessionView`'s scene-phase branch
    /// owns the other half — because a session cannot follow somebody somewhere
    /// it cannot reach them, and the next best thing is to say where it got to.
    /// Wanting a felt session with the phone away is the wrist's to answer.
    var playsInBackground: Bool {
        audio != nil
    }

    func prepare() {
        haptics?.prepare()
        audio?.prepare()
    }

    /// Only the audio side has anything to hand back: the haptic engine plays
    /// nothing between boundaries, so a pause costs it nothing to sit through.
    func pause() {
        audio?.pause()
    }

    func resume() {
        audio?.resume()
    }

    func play(_ beat: SessionTimeline.Beat) {
        haptics?.play(beat)
        audio?.play(beat)
    }

    func playCompletion() {
        haptics?.playCompletion()
        audio?.playCompletion()
    }

    func stop() {
        haptics?.stop()
        audio?.stop()
    }
}
