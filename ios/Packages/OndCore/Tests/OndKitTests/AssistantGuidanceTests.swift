import OndAPI
@testable import OndKit
import Testing

@Suite("Assistant guidance")
@MainActor
struct AssistantGuidanceTests {
    /// The boundary rule every enum here follows: a value this app cannot
    /// represent is a decode failure, never a silent default. Guessing
    /// `.fallback` would look like the safe choice and would have the app tell
    /// somebody their guidance was not personalised when the server never said
    /// so.
    @Test("An unrepresentable source is refused rather than guessed")
    func rejectsAnUnspecifiedSource() {
        #expect(GuidanceSource(proto: .model) == .model)
        #expect(GuidanceSource(proto: .fallback) == .fallback)
        #expect(GuidanceSource(proto: .unspecified) == nil)
        #expect(GuidanceSource(proto: .UNRECOGNIZED(99)) == nil)
    }

    /// The whole point of the streaming RPC, and the one assertion that fails if
    /// the model collects the stream and publishes once: the running text is
    /// readable *between* chunks, marked incomplete, and becomes complete only
    /// when the stream ends.
    @Test("Text is published between chunks, not only at the end")
    func publishesWhileStreaming() async throws {
        let script = Script()
        let model = ExplanationModel(assistant: script.assistant, techniqueSlug: "extended-exhale")

        model.startIfNeeded()
        script.yield(AssistantChunk(text: "A longer exhale ", source: .model))
        try await settle()

        #expect(
            model.state == .reading(
                text: "A longer exhale ",
                source: .model,
                isComplete: false
            ),
            "the first chunk is readable before the second arrives"
        )

        script.yield(AssistantChunk(text: "lengthens each breath.", source: .model))
        try await settle()

        #expect(
            model.state == .reading(
                text: "A longer exhale lengthens each breath.",
                source: .model,
                isComplete: false
            )
        )

        script.finish()
        try await settle()

        #expect(
            model.state == .reading(
                text: "A longer exhale lengthens each breath.",
                source: .model,
                isComplete: true
            )
        )
    }

    /// A stream that dies after some text keeps the text — half an explanation is
    /// still worth reading, and swapping it for a placeholder takes away
    /// something the person is in the middle of — but it is not *finished*.
    ///
    /// `isComplete` is what the view captions the paragraph with, so the two
    /// halves of this assertion guard opposite mistakes: dropping the text, and
    /// presenting a sentence that stops mid-word as the whole answer.
    @Test("A break mid-answer keeps what arrived, uncaptioned as complete")
    func keepsPartialTextOnFailure() async throws {
        let script = Script()
        let model = ExplanationModel(assistant: script.assistant, techniqueSlug: "box-breathing")

        model.startIfNeeded()
        script.yield(AssistantChunk(text: "The mechanism is ", source: .fallback))
        script.finish(throwing: AssistantRepositoryError.transport("the stream broke"))
        try await settle()

        #expect(
            model.state == .reading(
                text: "The mechanism is ",
                source: .fallback,
                isComplete: false
            )
        )
    }

    /// A failure before any text has nothing to keep, and the view is told so —
    /// the one state that renders the calm placeholder rather than an error.
    @Test("A failure before the first chunk is unavailable, not empty text")
    func reportsUnavailableWhenNothingArrives() async throws {
        let script = Script()
        let model = ExplanationModel(assistant: script.assistant, techniqueSlug: "box-breathing")

        model.startIfNeeded()
        script.finish(throwing: AssistantRepositoryError.transport("no network"))
        try await settle()

        #expect(model.state == .unavailable)
    }

    /// The guidance strip has no failure state: an unreachable server leaves it
    /// absent, and the catalogue underneath is unaffected. A model that surfaced
    /// the error would put a network message on a screen about breathing.
    @Test("Unreachable guidance leaves the strip empty rather than failing")
    func guidanceFailsQuietly() async {
        let model = GuidanceModel(assistant: FailingAssistant())

        await model.loadIfNeeded()

        guard case .unavailable = model.state else {
            Issue.record("an unreachable server leaves nothing to show, not an error")
            return
        }
    }

    /// Lets the model's reader task drain what the script has yielded.
    ///
    /// A sleep rather than a single `Task.yield()`: the reader runs on its own
    /// task, and yielding once does not reliably carry it through a loop
    /// iteration.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A stream the test drives chunk by chunk.
///
/// Deliberately not a stub that yields everything at once: publishing between
/// chunks is the behaviour under test, and a stub that emitted the whole answer
/// in one go could not tell a model that streams apart from one that buffers.
private final class Script {
    let assistant: any AssistantReading

    private let continuation: AsyncThrowingStream<AssistantChunk, Error>.Continuation

    init() {
        let (stream, continuation) = AsyncThrowingStream<AssistantChunk, Error>.makeStream()
        self.continuation = continuation
        assistant = ScriptedAssistant(stream: stream)
    }

    func yield(_ chunk: AssistantChunk) {
        continuation.yield(chunk)
    }

    func finish(throwing error: (any Error)? = nil) {
        continuation.finish(throwing: error)
    }
}

private struct ScriptedAssistant: AssistantReading, @unchecked Sendable {
    /// Consumed once, by the single model each test builds.
    let stream: AsyncThrowingStream<AssistantChunk, Error>

    func recommendations() async throws -> Guidance {
        Guidance(recommendations: [], source: .fallback)
    }

    func explanation(of _: String) -> AsyncThrowingStream<AssistantChunk, Error> {
        stream
    }

    func chat(
        history _: [ChatTurn],
        message _: String
    ) -> AsyncThrowingStream<AssistantChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct FailingAssistant: AssistantReading {
    func recommendations() async throws -> Guidance {
        throw AssistantRepositoryError.transport("no network")
    }

    func explanation(of _: String) -> AsyncThrowingStream<AssistantChunk, Error> {
        AsyncThrowingStream {
            $0.finish(throwing: AssistantRepositoryError.transport("no network"))
        }
    }

    func chat(
        history _: [ChatTurn],
        message _: String
    ) -> AsyncThrowingStream<AssistantChunk, Error> {
        AsyncThrowingStream {
            $0.finish(throwing: AssistantRepositoryError.transport("no network"))
        }
    }
}
