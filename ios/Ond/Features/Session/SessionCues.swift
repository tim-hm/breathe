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

    /// Sound is the whole of the answer, and deliberately so.
    ///
    /// The runtime a backgrounded session lives on is granted for playing audio,
    /// so a session with sound switched off has no honest claim to it — and it is
    /// the claim, not the code, that App Review reads. Haptics only therefore
    /// keeps pausing on departure, which is a real gap for the mode most likely
    /// to be used with the eyes shut. Closing it means answering whether
    /// CoreHaptics fires at all in a backgrounded app, and that question has no
    /// answer off a physical device.
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
