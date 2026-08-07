@testable import BreatheKit
import Foundation
import Testing

/// When the audio session and the haptic engine are handed back.
///
/// The release used to be reachable only through the view's `onDisappear`, and
/// for a session that *finished* that is whenever somebody closes the summary —
/// so an `AVAudioSession` active in `.playback` kept every other app's audio
/// ducked for as long as the phone sat on the table. Deferring past the
/// completion cue is deliberate; leaving the deferral unbounded was not.
@MainActor
@Suite("Releasing the cue hardware")
struct SessionCueReleaseTests {
    @Test("A finished session hands the hardware back without waiting for the screen to go")
    func releasesWithoutADismiss() async throws {
        let cues = RecordingCues()
        let model = SessionModel(
            technique: briefBreathing(),
            cues: cues,
            recorder: DiscardingRecorder()
        )

        model.start()
        try await waitFor("the plan to run out") { model.status == .finished }
        #expect(cues.completions == 1)
        #expect(cues.stops == 0, "the completion cue is still playing on the hardware")

        // Nothing here ever calls `dismiss()`: the summary is on screen and the
        // cover is still presented, which is the state the release has to reach
        // by itself.
        try await waitFor(
            "the cue hardware to be released",
            within: SessionModel.cueReleaseDelay + .seconds(1)
        ) { cues.stops > 0 }

        model.dismiss()
        #expect(cues.stops == 2, "the backstop still runs, and stopping twice is harmless")
    }
}

/// Which pauses undo themselves.
///
/// iOS sends `.inactive` for a notification banner as readily as for a real
/// departure, so the session pauses only on `.background` — and then has to come
/// back on its own, because the person it stopped has their eyes closed and no
/// reason to think the screen needs them.
@MainActor
@Suite("Pausing when the app leaves")
struct SessionScenePauseTests {
    @Test("A session paused by the app leaving resumes when it returns")
    func resumesAScenePause() async throws {
        let model = SessionModel(
            technique: briefBreathing(cycles: 1000),
            cues: RecordingCues(),
            recorder: DiscardingRecorder()
        )
        model.start()
        try await waitFor("the session to be running") { model.status == .running }

        model.pauseForScene()
        #expect(model.status == .paused)

        model.resumeIfSceneDriven()
        #expect(model.status == .running)
    }

    /// The half that makes the flag worth having: a person who reached for Pause
    /// must not have the breathing started up again under them by a banner
    /// clearing.
    @Test("A session paused by hand is left alone")
    func leavesAHandPauseAlone() async throws {
        let model = SessionModel(
            technique: briefBreathing(cycles: 1000),
            cues: RecordingCues(),
            recorder: DiscardingRecorder()
        )
        model.start()
        try await waitFor("the session to be running") { model.status == .running }

        model.pause()
        // Backgrounding an already-paused session claims nothing, so the return
        // to the foreground has nothing to undo.
        model.pauseForScene()
        model.resumeIfSceneDriven()

        #expect(model.status == .paused)
    }
}
