import BreatheKit
import Foundation
import Testing

/// The open-ended retention, which is the one place the session's two clocks
/// come apart: the plan stops at the top of the hold while the person's own time
/// keeps running, and the tap splices the plan back on at the hold's end.
///
/// The fixture holds first and breathes second so these run in milliseconds. The
/// hold is seeded at a nominal minute precisely so that a plan-time reading and
/// a wall-clock reading cannot be mistaken for one another.
@MainActor
@Suite("Ending a hold the clock cannot")
struct SessionHoldTests {
    private static let retention = Technique(
        id: "id",
        slug: "wim-hof-rounds",
        name: "Wim Hof-style Rounds",
        summary: "",
        goal: .energy,
        stages: [
            Stage(
                phases: [Phase(kind: .holdOut, duration: .milliseconds(60000))],
                cycles: 1,
                openEnded: true
            ),
            Stage(phases: [Phase(kind: .inhale, duration: .milliseconds(100))], cycles: 1),
        ],
        recommendedRounds: 1
    )

    private func startedSession() async throws -> (SessionModel, RecordingCues) {
        let cues = RecordingCues()
        let model = SessionModel(
            technique: Self.retention,
            cues: cues,
            recorder: DiscardingRecorder()
        )
        model.start()
        try await waitFor("the hold to begin") { model.status == .holding }
        return (model, cues)
    }

    @Test("The plan stops inside a hold while the person's own time does not")
    func stopsThePlanForAHold() async throws {
        let (model, cues) = try await startedSession()

        #expect(model.elapsed == .zero, "the plan is pinned to the top of the hold")
        #expect(cues.played.count == 1, "the hold is cued once, on entry")

        try await Task.sleep(for: .milliseconds(60))

        #expect(model.elapsed == .zero, "the plan has still not moved")
        #expect(model.realElapsed >= .milliseconds(50), "but the person has been holding")
        #expect(model.holdElapsed >= .milliseconds(50))
        #expect(model.status == .holding)
    }

    /// The plan resumes at the *end* of the hold's beat, however long the hold
    /// took — a short retention must not skip the recovery breath, and a long
    /// one must not eat it.
    @Test("Releasing a hold splices the plan back on at the hold's end")
    func splicesThePlanOnRelease() async throws {
        let (model, _) = try await startedSession()
        try await Task.sleep(for: .milliseconds(30))

        model.release()

        #expect(model.status == .running)
        #expect(model.elapsed >= .milliseconds(60000), "the plan jumped the whole hold")
        #expect(model.holdElapsed == .zero)

        try await waitFor("the session to finish") { model.status == .finished }

        let record = try #require(model.record)
        #expect(record.completed)
        #expect(record.cyclesCompleted == 2)
        // The plan is a minute long and this session was not. The recorded
        // duration is wall-clock, so the nominal hold cannot leak into it.
        #expect(record.duration < .seconds(5))
        #expect(record.duration >= .milliseconds(30))
    }

    /// A pause inside a hold is not the end of the hold. Resuming has to land
    /// back in it — anywhere else and the person loses a retention they were
    /// still in — and the hold's own timer has to pick up where it stopped.
    @Test("A pause inside a hold resumes into the same hold")
    func resumesIntoTheHold() async throws {
        let (model, cues) = try await startedSession()
        try await Task.sleep(for: .milliseconds(30))

        model.pause()
        #expect(model.status == .paused)

        let heldWhenPaused = model.holdElapsed
        #expect(heldWhenPaused >= .milliseconds(30))
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.holdElapsed == heldWhenPaused, "a paused hold does not count time")

        model.resume()
        #expect(model.status == .holding)
        #expect(model.holdElapsed >= heldWhenPaused, "the hold's timer carried on")
        #expect(model.elapsed == .zero, "and the plan is still pinned")
        #expect(cues.played.count == 1, "resuming mid-hold does not re-cue it")
    }

    /// Ending a session mid-hold records what happened rather than what was
    /// planned: the hold was entered but never finished, so its cycle is not one
    /// the person is told they completed.
    @Test("Ending inside a hold records the hold as unfinished")
    func endsInsideAHold() async throws {
        let (model, _) = try await startedSession()
        try await Task.sleep(for: .milliseconds(20))

        model.end()

        let record = try #require(model.record)
        #expect(!record.completed)
        #expect(record.cyclesCompleted == 0)
        #expect(record.duration < .seconds(5))
    }
}

/// Remembers what it was asked to play, so a test can assert a beat was cued
/// once rather than on every turn of the loop.
@MainActor
final class RecordingCues: SessionCueing {
    private(set) var played: [SessionTimeline.Beat] = []
    private(set) var completions = 0

    func prepare() {}

    func play(_ beat: SessionTimeline.Beat) {
        played.append(beat)
    }

    func playCompletion() {
        completions += 1
    }

    func stop() {}
}

/// A session store that keeps nothing. The record under test is the one on the
/// model; what the store does with it is `SessionStoreTests`' business.
struct DiscardingRecorder: SessionRecording {
    func record(_: SessionRecord) async {}

    func recordedSessions() async -> [SessionRecord] {
        []
    }
}

/// Polls `condition` until it holds, because what is being waited on is a cue
/// loop sleeping on a clock rather than an operation with a handle to await.
@MainActor
func waitFor(_ description: String, until condition: @MainActor () -> Bool) async throws {
    for _ in 0 ..< 200 {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for \(description)")
}
