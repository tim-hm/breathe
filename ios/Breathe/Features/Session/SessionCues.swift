import BreatheKit

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

    init(mode: SessionCueMode) {
        haptics = mode.playsHaptics ? HapticController() : nil
        audio = mode.playsAudio ? SessionAudioPlayer() : nil
    }

    func prepare() {
        haptics?.prepare()
        audio?.prepare()
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
