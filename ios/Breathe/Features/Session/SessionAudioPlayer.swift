import AVFoundation
import BreatheKit
import os

/// The audible half of a cue: one soft tone per phase, a rising triad at the end.
///
/// Pitch carries the direction — the inhale sits above the exhale, the two holds
/// sit outside both — so the tones remain distinguishable at a volume low enough
/// to breathe to.
@MainActor
final class SessionAudioPlayer {
    private static let logger = Logger(subsystem: "xyz.holmie.breathe", category: "audio")

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
            Self.logger.error("audio session unavailable: \(error.localizedDescription)")
            return
        }

        players = Self.cueTones.compactMapValues(player(for:))
        completionPlayer = player(for: Self.completionTone)
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

        do {
            // Telling other apps we are done is what lets a paused music app
            // resume on its own rather than waiting for the user to notice.
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            Self.logger.error("audio session would not deactivate: \(error.localizedDescription)")
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
            Self.logger.error("cue tone would not load: \(error.localizedDescription)")
            return nil
        }
    }
}
