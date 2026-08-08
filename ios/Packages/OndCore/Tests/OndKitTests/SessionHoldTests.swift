import Foundation
import OndKit
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

    /// A retention with a stage on each side of it — breathe, hold, recover —
    /// which is the shape a Wim Hof-style round actually has and the one
    /// `retention` does not: that fixture opens on the hold, so nothing there
    /// says the plan resumes into a *following stage* rather than merely into
    /// the next beat of the same one.
    ///
    /// The breathing either side runs in tens of milliseconds so the test does
    /// not, while the hold keeps its nominal minute for the same reason as above.
    private static let sequence = Technique(
        id: "id",
        slug: "wim-hof-rounds",
        name: "Wim Hof-style Rounds",
        summary: "",
        goal: .energy,
        stages: [
            Stage(
                phases: [
                    Phase(kind: .inhale, duration: .milliseconds(30)),
                    Phase(kind: .exhale, duration: .milliseconds(30)),
                ],
                cycles: 1
            ),
            Stage(
                phases: [Phase(kind: .holdOut, duration: .milliseconds(60000))],
                cycles: 1,
                openEnded: true
            ),
            Stage(phases: [Phase(kind: .holdIn, duration: .milliseconds(30))], cycles: 1),
        ],
        recommendedRounds: 1
    )

    private func startedSession(
        of technique: Technique = SessionHoldTests.retention
    ) async throws -> (SessionModel, RecordingCues) {
        let cues = RecordingCues()
        let model = SessionModel(
            technique: technique,
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

    /// The clause chaining stages has to not break: a hold the person ends,
    /// reached partway through a sequence, stops the plan where it stands and
    /// hands the rest of the sequence back when they release it.
    ///
    /// Nothing about the hold is special-cased on position, and this is what
    /// keeps it that way — a plan that resumed at the wrong offset would skip or
    /// repeat the recovery stage, which is the part of the protocol the hold
    /// exists to be followed by.
    @Test("A hold partway through a sequence stops the clock and hands the rest back")
    func holdsInsideASequence() async throws {
        let (model, cues) = try await startedSession(of: Self.sequence)

        let held = try #require(model.currentBeat)
        #expect(held.stage == 1, "the hold is the second of three stages")
        #expect(
            model.elapsed == .milliseconds(60),
            "the plan is pinned at the top of the hold, not at zero"
        )

        try await Task.sleep(for: .milliseconds(40))
        #expect(model.elapsed == .milliseconds(60), "and it has not moved")
        #expect(model.realElapsed >= .milliseconds(60), "while the person has been holding")

        model.release()

        #expect(model.status == .running)
        #expect(
            model.elapsed >= .milliseconds(60060),
            "the plan jumped the whole hold and landed in the stage after it"
        )

        try await waitFor("the session to finish") { model.status == .finished }

        // Which stages were cued and in what order, rather than how many beats
        // of each: a wake-up late by more than a 30 ms phase legitimately skips
        // cueing it, and a test that counted beats would fail on a busy machine
        // for a reason that is not a bug.
        let cued = cues.played.map(\.stage)
        #expect(cued.first == 0, "the sequence began in the stage before the hold")
        #expect(cued.filter { $0 == 1 }.count == 1, "the hold was cued once, on entry")
        #expect(cued.last == 2, "and the stage after it ran once the hold was released")
        #expect(cued == cued.sorted(), "no stage was cued out of order")

        let record = try #require(model.record)
        #expect(record.completed)
        #expect(record.cyclesCompleted == 3, "one cycle from each stage")
        // The plan is a minute long and this session was not.
        #expect(record.duration < .seconds(5))
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

/// Two 30 ms breaths, so a session runs out inside a test rather than inside a
/// technique. `cycles` is how the same fixture serves both a run that finishes
/// and one that cannot: a thousand cycles outlives any test that ends it by hand.
@MainActor
func briefBreathing(cycles: Int = 1) -> Technique {
    Technique(
        id: "id",
        slug: "box-breathing",
        name: "Box Breathing",
        summary: "",
        goal: .calm,
        stages: [
            Stage(
                phases: [
                    Phase(kind: .inhale, duration: .milliseconds(30)),
                    Phase(kind: .exhale, duration: .milliseconds(30)),
                ],
                cycles: cycles
            ),
        ],
        recommendedRounds: 1
    )
}

/// Remembers what it was asked to play, so a test can assert a beat was cued
/// once rather than on every turn of the loop.
@MainActor
final class RecordingCues: SessionCueing {
    private(set) var played: [SessionTimeline.Beat] = []
    private(set) var completions = 0
    /// Counted, not just flagged: the hardware is released from two places and
    /// the interesting failure is both of them firing.
    private(set) var stops = 0

    /// Defaulted to the answer that makes a departure stop the session, because
    /// that is the behaviour every suite here predates. Only the background
    /// suite passes the other one.
    let playsInBackground: Bool

    init(playsInBackground: Bool = false) {
        self.playsInBackground = playsInBackground
    }

    /// Counted rather than flagged for the same reason `stops` is: what the
    /// background suite asserts is that a pause hands the runtime back exactly
    /// once and a resume takes it again, not merely that both were mentioned.
    private(set) var pauses = 0
    private(set) var resumes = 0

    func prepare() {}

    func pause() {
        pauses += 1
    }

    func resume() {
        resumes += 1
    }

    func play(_ beat: SessionTimeline.Beat) {
        played.append(beat)
    }

    func playCompletion() {
        completions += 1
    }

    func stop() {
        stops += 1
    }
}

/// A session store that keeps nothing. The record under test is the one on the
/// model; what the store does with it is `SessionStoreTests`' business.
struct DiscardingRecorder: SessionRecording {
    func record(_: SessionRecord) async {}

    func remove(_: SessionRecord.ID) async {}

    func merge(_: [SessionRecord]) async -> Bool {
        false
    }

    func recordedSessions() async -> [SessionRecord] {
        []
    }
}

/// Polls `condition` until it holds, because what is being waited on is a cue
/// loop sleeping on a clock rather than an operation with a handle to await.
///
/// - Parameter timeout: how long to keep asking. The default suits the
///   millisecond fixtures these suites are built from; a caller waiting on a
///   deliberate delay passes that delay plus slack.
@MainActor
func waitFor(
    _ description: String,
    within timeout: Duration = .seconds(1),
    until condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for \(description)")
}
