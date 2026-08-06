import BreatheKit
import Foundation
import Testing

/// The rule that keeps the journal honest: a session ended by hand inside the
/// first ten seconds was a false start, and false starts are not practice.
@MainActor
@Suite("Discarding false starts")
struct SessionDiscardTests {
    /// Remembers what it was asked to keep, so a test can assert on "nothing".
    private actor CountingRecorder: SessionRecording {
        private(set) var kept: [SessionRecord] = []

        func record(_ session: SessionRecord) async {
            kept.append(session)
        }

        func remove(_: SessionRecord.ID) async {}

        func merge(_: [SessionRecord]) async -> Bool {
            false
        }

        func recordedSessions() async -> [SessionRecord] {
            kept
        }
    }

    /// Milliseconds long, so a completed run still finishes well inside the
    /// discard window — which is exactly what makes it prove the exemption.
    private static func technique(cycles: Int = 1) -> Technique {
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

    @Test("Ending inside the first seconds records nothing")
    func discardsAQuickCancel() async throws {
        let recorder = CountingRecorder()
        let model = SessionModel(
            technique: Self.technique(cycles: 1000),
            cues: RecordingCues(),
            recorder: recorder
        )

        model.start()
        try await Task.sleep(for: .milliseconds(40))
        model.end()

        #expect(model.status == .finished)
        #expect(model.wasDiscarded)
        // The record still exists on the model — the discard is about the
        // journal, not about lying to the screen that just ended.
        #expect(model.record != nil)

        // The write is fired on a Task; give it a beat to have happened if it
        // wrongly would.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.kept.isEmpty)
    }

    /// Finishing the plan is practice however short the plan was — the
    /// exemption that keeps a deliberately brief technique recordable.
    @Test("A completed session is kept however short it was")
    func keepsAShortCompletion() async throws {
        let recorder = CountingRecorder()
        let model = SessionModel(
            technique: Self.technique(cycles: 2),
            cues: RecordingCues(),
            recorder: recorder
        )

        model.start()
        try await waitFor("the plan to run out") { model.status == .finished }

        #expect(!model.wasDiscarded)
        #expect(model.record?.completed == true)

        // The write rides an unstructured Task; poll rather than assume it
        // has landed by the time the status flipped.
        for _ in 0 ..< 100 {
            if await !recorder.kept.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.kept.count == 1)
    }
}
