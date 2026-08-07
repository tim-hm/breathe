import AVFoundation
import Foundation

/// The on-device [`CoachVoice`]: `AVSpeechSynthesizer` with the system voice.
///
/// V1 by product decision — no network, no per-sentence cost, and a voice the
/// person has already heard elsewhere on their phone. The neural upgrade is a
/// second implementation of the protocol, not a change here.
public final class SystemCoachVoice: NSObject, CoachVoice {
    private let synthesizer = AVSpeechSynthesizer()

    override public init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ sentence: String) {
        // Claimed on the transition into speaking, not per sentence: the
        // session calls are synchronous IPC on the main actor, and a reply
        // hands over a sentence at a time.
        if !synthesizer.isSpeaking {
            activatePlayback()
        }
        // No explicit voice: `AVSpeechUtterance` falls back to the system
        // voice for the current locale, which follows the person's own
        // settings — including any premium voice they have downloaded.
        synthesizer.speak(AVSpeechUtterance(string: sentence))
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivatePlayback()
    }

    /// Claims the audio session for spoken word.
    ///
    /// `.playback` with `.duckOthers`: whatever the person is listening to
    /// dips underneath the coach and comes back up when the reply ends,
    /// rather than stopping outright. `.playback` also means the voice plays
    /// through the silent switch — deliberate, and the convention spoken-word
    /// apps follow: the person just tapped the speak-back toggle, and a voice
    /// that silently said nothing would read as broken.
    private func activatePlayback() {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, options: .duckOthers)
            try? session.setActive(true)
        #endif
    }

    /// Gives the audio session back so ducked audio returns to full volume.
    /// `try?` on both calls here and above: audio-session failures are not
    /// actionable by the person, and a reply that plays un-ducked beats one
    /// that never plays.
    private func deactivatePlayback() {
        #if os(iOS)
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

extension SystemCoachVoice: AVSpeechSynthesizerDelegate {
    /// Releases the audio session once the queue drains, so background audio
    /// un-ducks at the end of a reply without the person having to tap stop.
    ///
    /// `nonisolated` with a hop rather than an isolated conformance, because
    /// AVFoundation does not promise which thread calls its delegates — a
    /// main-actor conformance would turn that unpromise into a crash.
    public nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didFinish _: AVSpeechUtterance
    ) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking {
                self.deactivatePlayback()
            }
        }
    }
}
