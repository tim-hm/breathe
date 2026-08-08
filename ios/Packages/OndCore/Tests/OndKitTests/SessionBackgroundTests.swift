import Foundation
@testable import OndKit
import Testing

/// What happens to a session when the app stops being looked at.
///
/// Eyes closed with the screen off is the posture these techniques are done in,
/// so on the phone the departure is only an interruption when the cues cannot
/// follow the person into it. The session asks the cue channel which it is; these
/// pin both answers, and the third pins the one thing that must not change with
/// either — a pause somebody reached for stays a pause.
@MainActor
@Suite("Backgrounding a session")
struct SessionBackgroundTests {
    @Test("A session whose cues play in the background is not stopped by leaving")
    func keepsRunningWhenTheCuesDo() async throws {
        let model = SessionModel(
            technique: briefBreathing(cycles: 1000),
            cues: RecordingCues(playsInBackground: true),
            recorder: DiscardingRecorder()
        )
        model.start()
        try await waitFor("the session to be running") { model.status == .running }

        model.pauseForScene()

        #expect(
            model.status == .running,
            "the phone going dark is the technique, not an interruption"
        )
    }

    /// The regression this issue exists for, stated as time rather than as
    /// status: a session that is away for a while has to come back to where the
    /// plan actually is, not to where it was when it left. Both halves are worth
    /// asserting — a frozen session fails the lower bound, and one that banked
    /// its position and then counted the gap twice fails the upper.
    @Test("Time away is time in the session, not time owed to it")
    func staysOnTheWallClock() async throws {
        let model = SessionModel(
            technique: briefBreathing(cycles: 1000),
            cues: RecordingCues(playsInBackground: true),
            recorder: DiscardingRecorder()
        )
        model.start()
        try await waitFor("the session to be running") { model.status == .running }

        let departed = model.elapsed
        model.pauseForScene()
        let away = Duration.milliseconds(200)
        try await Task.sleep(for: away)
        model.resumeIfSceneDriven()

        let advanced = model.elapsed - departed
        #expect(advanced >= away, "the session lost the time it spent backgrounded")
        // The cue loop is the only thing that could have double-counted the gap,
        // and the slack is for the scheduler rather than for drift.
        #expect(advanced < away + .milliseconds(150), "the session counted the gap twice")
    }

    /// The `Done when:` clause that is about what did *not* change. Background
    /// runtime is a reason not to pause on a departure; it was never a reason to
    /// overrule the person, and a hand pause that undid itself because a banner
    /// dropped is the failure the scene flag exists to prevent.
    @Test("A hand pause survives a departure and a return")
    func leavesAHandPauseAlone() async throws {
        let model = SessionModel(
            technique: briefBreathing(cycles: 1000),
            cues: RecordingCues(playsInBackground: true),
            recorder: DiscardingRecorder()
        )
        model.start()
        try await waitFor("the session to be running") { model.status == .running }

        model.pause()
        model.pauseForScene()
        model.resumeIfSceneDriven()

        #expect(model.status == .paused)
    }

    /// The other half of holding the app open: a pause has to give the runtime
    /// back. Left playing, a session somebody paused and walked away from would
    /// keep the phone awake for as long as they stayed away — the battery cost of
    /// a feature nobody is using.
    @Test("A pause hands the runtime back, and a resume takes it again")
    func releasesTheRuntimeWhilePaused() async throws {
        let cues = RecordingCues(playsInBackground: true)
        let model = SessionModel(
            technique: briefBreathing(cycles: 1000),
            cues: cues,
            recorder: DiscardingRecorder()
        )
        model.start()
        try await waitFor("the session to be running") { model.status == .running }

        model.pause()
        #expect(cues.pauses == 1)

        model.resume()
        // Two, not one: starting the session is itself a claim on the runtime,
        // and the resume is the second. What matters is that no pause goes
        // unanswered, not that the claims are minimal.
        #expect(cues.resumes == 2)
    }
}
