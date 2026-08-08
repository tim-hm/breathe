import AVFoundation
import OndKit
import os

/// The audible half of a cue: one soft tone per phase, a rising triad at the end
/// — and, underneath them, what keeps the app alive to play any of it.
///
/// Pitch carries the direction — the inhale sits above the exhale, the two holds
/// sit outside both — so the tones remain distinguishable at a volume low enough
/// to breathe to.
///
/// The phone has no `WKExtendedRuntimeSession` the way the watch does, so the
/// only runtime a backgrounded session can hold is the one `UIBackgroundModes:
/// audio` grants an app that is playing. That budget lasts exactly as long as
/// the playing does, and a cue tone is under a second inside a phase that runs
/// for eleven — so the tones alone buy the first gap and nothing after it. The
/// silence loop below is what makes the gaps the inside of one playback, and it
/// is why this type, not the haptics beside it, is what `playsInBackground`
/// answers for.
@MainActor
final class SessionAudioPlayer {
    private static let logger = Logger(category: "audio")

    /// One second, looped. `AVAudioPlayer` repeats from its own buffer without
    /// the app being woken for it, so the length buys nothing but the 88 KB it
    /// costs to hold.
    private static let silenceLoop = ToneSynthesizer.silence(seconds: 1)

    /// Synthesised once for the process rather than per session: the tones never
    /// vary, and building them is a few hundred thousand `sin` calls that would
    /// otherwise land on the main thread as the player animates in.
    private static let cueTones: [PhaseKind: Data] = [
        .inhale: ToneSynthesizer.wav([ToneSynthesizer.Note(440, duration: 0.55)]),
        .exhale: ToneSynthesizer.wav([ToneSynthesizer.Note(330, duration: 0.7)]),
        .holdIn: ToneSynthesizer.wav([ToneSynthesizer.Note(587, duration: 0.22)]),
        .holdOut: ToneSynthesizer.wav([ToneSynthesizer.Note(262, duration: 0.28)]),
    ]

    private static let completionTone = ToneSynthesizer.wav([
        ToneSynthesizer.Note(440, start: 0, duration: 0.5),
        ToneSynthesizer.Note(554, start: 0.18, duration: 0.5),
        ToneSynthesizer.Note(659, start: 0.36, duration: 0.9),
    ])

    private var players: [PhaseKind: AVAudioPlayer] = [:]
    private var completionPlayer: AVAudioPlayer?
    private var silence: AVAudioPlayer?

    func prepare() {
        do {
            // `.playback` so a session keeps its voice with the ring switch off
            // — a phone silenced for a meeting is exactly when someone reaches
            // for this. `.mixWithOthers` because breathing to your own music is
            // a reasonable thing to want, and interrupting it is not our call.
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.logger
                .error("audio session unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }

        players = Self.cueTones.compactMapValues(player(for:))
        completionPlayer = player(for: Self.completionTone)

        silence = player(for: Self.silenceLoop)
        // Endlessly, and started before the first beat: the runtime has to
        // already be held when the person locks the phone, which they may well
        // do during the count-in.
        silence?.numberOfLoops = -1
        silence?.play()
    }

    /// Hands the runtime back for as long as the pause lasts, and takes it again
    /// on the way out. `pause()` rather than `stop()` on the loop: stopping
    /// rewinds it, and this player is never anywhere worth returning to.
    func pause() {
        silence?.pause()
    }

    func resume() {
        silence?.play()
    }

    func play(_ beat: SessionTimeline.Beat) {
        guard let player = players[beat.kind] else { return }
        // Rewound rather than restarted: a cue still ringing when the next phase
        // arrives should be replaced by it, not queued behind it.
        player.currentTime = 0
        player.play()
    }

    func playCompletion() {
        completionPlayer?.currentTime = 0
        completionPlayer?.play()
    }

    func stop() {
        for player in players.values {
            player.stop()
        }
        players.removeAll()
        completionPlayer?.stop()
        completionPlayer = nil
        // Before the session is deactivated, and not left to deinit: this is the
        // one player that would otherwise go on holding background runtime for a
        // session that has finished.
        silence?.stop()
        silence = nil

        do {
            // Telling other apps we are done is what lets a paused music app
            // resume on its own rather than waiting for the user to notice.
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            Self.logger
                .error(
                    "audio session would not deactivate: \(error.localizedDescription, privacy: .public)"
                )
        }
    }

    private func player(for tone: Data) -> AVAudioPlayer? {
        do {
            let player = try AVAudioPlayer(data: tone)
            // Decoding and buffer allocation happen here rather than on the
            // first phase boundary, where the delay would land inside the cue.
            player.prepareToPlay()
            return player
        } catch {
            Self.logger
                .error("cue tone would not load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
