import Foundation
@testable import OndKit
import Testing

@Suite("Coach chat")
@MainActor
struct CoachChatTests {
    /// The transcript is readable between chunks — the person's turn lands
    /// immediately, the coach's row appears with the first chunk and grows in
    /// place, keeping one identity so the view animates a paragraph filling
    /// in rather than replacing rows.
    @Test("The reply grows in place while streaming")
    func replyAccumulatesAcrossChunks() async throws {
        let script = ChatScript()
        let model = CoachChatModel(assistant: script.assistant, voice: SpyCoachVoice())

        model.send("What helps with sleep?")
        try await settle(until: { model.isReplying })

        #expect(model.transcript.count == 1, "the person's turn lands before any reply")
        #expect(model.transcript[0].role == .person)
        #expect(model.isReplying)

        script.yield(AssistantChunk(text: "A longer exhale ", source: .model))
        try await settle(until: { model.transcript.count == 2 })
        let replyId = model.transcript[1].id

        script.yield(AssistantChunk(text: "settles you.", source: .model))
        script.finish()
        try await settle(until: { !model.isReplying })

        #expect(model.transcript.count == 2)
        #expect(model.transcript[1].role == .coach)
        #expect(model.transcript[1].text == "A longer exhale settles you.")
        #expect(model.transcript[1].id == replyId, "the reply keeps one identity as it grows")
        #expect(!model.isReplying)
    }

    /// The voice is fed sentence by sentence as chunks stream — never the
    /// growing buffer, and never waiting for the stream to finish — and the
    /// unterminated remainder is spoken when the stream ends.
    @Test("Speaking follows sentence boundaries, not chunk boundaries")
    func speaksSentenceBySentence() async throws {
        let script = ChatScript()
        let voice = SpyCoachVoice()
        let model = CoachChatModel(assistant: script.assistant, voice: voice)
        model.isSpeakingAloud = true

        model.send("hello")
        script.yield(AssistantChunk(text: "Breathe out lo", source: .model))
        try await settle(until: { model.transcript.count == 2 })
        #expect(voice.spoken.isEmpty, "half a sentence is not handed to the voice")

        script.yield(AssistantChunk(text: "nger. Then rest", source: .model))
        try await settle(until: { !voice.spoken.isEmpty })
        #expect(voice.spoken == ["Breathe out longer."], "a sentence speaks as soon as it closes")

        script.yield(AssistantChunk(text: ". And settle", source: .model))
        script.finish()
        try await settle(until: { !model.isReplying })

        #expect(
            voice.spoken == ["Breathe out longer.", "Then rest.", "And settle"],
            "the stream ending completes the last sentence, punctuation or not"
        )
    }

    /// Silence is opt-in twice over: the voice never speaks while the toggle
    /// is off, and flipping it off mid-reply stops it immediately.
    @Test("The toggle gates and stops the voice")
    func toggleSilencesTheVoice() async throws {
        let script = ChatScript()
        let voice = SpyCoachVoice()
        let model = CoachChatModel(assistant: script.assistant, voice: voice)

        model.send("hello")
        script.yield(AssistantChunk(text: "First sentence. ", source: .model))
        try await settle(until: { model.transcript.count == 2 })
        #expect(voice.spoken.isEmpty, "speak-back is off by default")

        model.isSpeakingAloud = true
        script.yield(AssistantChunk(text: "Second sentence. ", source: .model))
        try await settle(until: { !voice.spoken.isEmpty })
        #expect(voice.spoken == ["Second sentence."])

        let stopsBeforeToggle = voice.stops
        model.isSpeakingAloud = false
        #expect(
            voice.stops == stopsBeforeToggle + 1,
            "turning the toggle off stops the voice mid-word"
        )
    }

    /// A new question makes the old answer's remainder noise: send stops the
    /// voice before anything else happens.
    @Test("Sending stops the voice")
    func sendStopsTheVoice() async throws {
        let script = ChatScript()
        let voice = SpyCoachVoice()
        let model = CoachChatModel(assistant: script.assistant, voice: voice)
        model.isSpeakingAloud = true

        model.send("first question")
        script.yield(AssistantChunk(text: "An answer. ", source: .model))
        script.finish()
        try await settle(until: { !model.isReplying })

        model.send("second question")
        try await settle(until: { voice.stops >= 1 })

        #expect(voice.stops >= 1, "the next question interrupts the reading")
    }

    /// The view's onDisappear path: cancel stops the stream and the voice
    /// together, so neither the request nor the monologue outlives the screen.
    @Test("Cancel stops the stream and the voice")
    func cancelStopsEverything() async throws {
        let script = ChatScript()
        let voice = SpyCoachVoice()
        let model = CoachChatModel(assistant: script.assistant, voice: voice)

        model.send("hello")
        script.yield(AssistantChunk(text: "The first part ", source: .model))
        try await settle(until: { model.transcript.count == 2 })

        let stopsBeforeCancel = voice.stops
        model.cancel()
        try await settle(until: { !model.isReplying })

        #expect(voice.stops == stopsBeforeCancel + 1)
        #expect(!model.isReplying)
        #expect(
            model.transcript.last?.text == "The first part ",
            "what arrived stays readable; cancellation adds no apology"
        )
    }

    /// Offline is one quiet sentence in the coach's row, and the composer
    /// stays alive: the next send works without any retry affordance.
    @Test("A failure before the reply is one quiet sentence, and sending still works")
    func failureLeavesAQuietSentence() async throws {
        let script = ChatScript()
        let model = CoachChatModel(assistant: script.assistant, voice: SpyCoachVoice())

        model.send("hello")
        script.finish(throwing: AssistantRepositoryError.transport("no network"))
        try await settle(until: { !model.isReplying })

        #expect(model.transcript.count == 2)
        #expect(model.transcript[1].role == .coach)
        #expect(model.transcript[1].text == CoachChatModel.unavailableReply)
        #expect(!model.isReplying, "the composer is live again")

        model.send("still there?")
        try await settle(until: { model.transcript.count == 3 })
        #expect(model.transcript.count == 3, "the next question goes through untouched")
    }

    /// A reply that breaks mid-answer keeps what arrived, with no quiet
    /// sentence stitched onto a paragraph the person is reading.
    @Test("A break mid-reply keeps the text that arrived")
    func midStreamFailureKeepsText() async throws {
        let script = ChatScript()
        let model = CoachChatModel(assistant: script.assistant, voice: SpyCoachVoice())

        model.send("hello")
        script.yield(AssistantChunk(text: "The mechanism is ", source: .model))
        script.finish(throwing: AssistantRepositoryError.transport("the stream broke"))
        try await settle(until: { !model.isReplying })

        #expect(model.transcript.count == 2)
        #expect(model.transcript[1].text == "The mechanism is ")
        #expect(!model.isReplying)
    }

    /// The history sent with each message is the transcript *before* that
    /// message — the server appends the new message itself, and doubling it
    /// would have the coach answer the question twice.
    @Test("Each send carries the prior transcript as history")
    func sendCarriesPriorHistory() async throws {
        let script = ChatScript()
        let model = CoachChatModel(assistant: script.assistant, voice: SpyCoachVoice())

        model.send("first")
        script.yield(AssistantChunk(text: "An answer.", source: .model))
        script.finish()
        try await settle(until: { !model.isReplying })

        model.send("second")
        try await settle(until: { script.calls.count == 2 })

        let call = try #require(script.calls.last)
        #expect(call.message == "second")
        #expect(call.history.map(\.text) == ["first", "An answer."])
        #expect(call.history.map(\.role) == [.person, .coach])
    }
}

@Suite("Sentence buffer")
struct SentenceBufferTests {
    /// Terminators close a sentence only when whitespace follows, so decimals
    /// and abbreviations mid-number survive chunk splits.
    @Test("A decimal point is not a sentence boundary")
    func decimalsSurvive() {
        var buffer = SentenceBuffer()
        #expect(buffer.append("Try a 4.") == [])
        #expect(buffer.append("7 rhythm tonight. It helps.") == ["Try a 4.7 rhythm tonight."])
        #expect(buffer.flush() == "It helps.")
    }

    /// Newlines end a sentence on their own — a paragraph break is a pause
    /// whether or not punctuation preceded it.
    @Test("A newline closes the sentence")
    func newlinesClose() {
        var buffer = SentenceBuffer()
        #expect(buffer.append("First thought\nSecond. ") == ["First thought", "Second."])
        #expect(buffer.flush() == nil)
    }
}

/// A recorded [`CoachVoice`]: what was spoken, in order, and how often it was
/// stopped. `AVSpeechSynthesizer` itself is deliberately not under test.
@MainActor
private final class SpyCoachVoice: CoachVoice {
    private(set) var spoken: [String] = []
    private(set) var stops = 0

    func speak(_ sentence: String) {
        spoken.append(sentence)
    }

    func stop() {
        stops += 1
    }
}

/// A chat stream the test drives chunk by chunk, recording what each call
/// carried — `Script`'s pattern from the guidance tests, plus capture.
@MainActor
private final class ChatScript {
    struct Call {
        let history: [ChatTurn]
        let message: String
    }

    private(set) var calls: [Call] = []
    private var continuation: AsyncThrowingStream<AssistantChunk, Error>.Continuation?

    var assistant: any AssistantReading {
        ScriptedChatAssistant(script: self)
    }

    func yield(_ chunk: AssistantChunk) {
        continuation?.yield(chunk)
    }

    func finish(throwing error: (any Error)? = nil) {
        continuation?.finish(throwing: error)
    }

    fileprivate func begin(
        history: [ChatTurn],
        message: String
    ) -> AsyncThrowingStream<AssistantChunk, Error> {
        calls.append(Call(history: history, message: message))
        let (stream, continuation) = AsyncThrowingStream<AssistantChunk, Error>.makeStream()
        self.continuation = continuation
        return stream
    }
}

private struct ScriptedChatAssistant: AssistantReading, @unchecked Sendable {
    let script: ChatScript

    func recommendations() async throws -> Guidance {
        Guidance(recommendations: [], source: .fallback)
    }

    func explanation(of _: String) -> AsyncThrowingStream<AssistantChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func chat(history: [ChatTurn], message: String) -> AsyncThrowingStream<AssistantChunk, Error> {
        MainActor.assumeIsolated {
            script.begin(history: history, message: message)
        }
    }
}
