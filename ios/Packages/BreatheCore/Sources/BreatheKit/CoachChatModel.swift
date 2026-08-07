import Foundation
import Observation
import os

/// The conversation with the coach: the transcript, the reply streaming into
/// it, and the voice reading that reply aloud.
///
/// `ExplanationModel`'s accumulate-and-republish pattern applied to a
/// transcript: the growing reply is republished on every chunk, so the
/// paragraph fills in as it is written. The transcript lives here, in memory,
/// for one app run — the server keeps no conversation state, and on-device
/// persistence is a flagged follow-up, not V1.
///
/// Failure is one quiet sentence in the transcript, never an error state: the
/// composer stays alive, nothing retries on its own, and a reply that broke
/// mid-answer keeps what arrived — half an answer is still worth reading.
@MainActor
@Observable
public final class CoachChatModel {
    /// What the transcript says when a reply never started. In the coach's
    /// row, not a banner: the conversation is the screen, so the conversation
    /// is where the answer — including this one — appears.
    static let unavailableReply =
        "The coach can't answer just now — nothing else is affected, so try again in a little while."

    private static let logger = Logger(category: "assistant")

    /// The conversation so far, oldest first. The last turn grows in place
    /// while a reply streams.
    public private(set) var transcript: [ChatTurn] = []

    /// Whether a reply is currently streaming. The view disables send — not
    /// the composer — while it is: typing the next question over a streaming
    /// answer is fine, interleaving two answers is not.
    public private(set) var isReplying = false

    /// The speak-back toggle. Turning it off silences the voice immediately;
    /// turning it on applies from the next reply, so the voice never starts
    /// mid-paragraph on text the person has already read.
    public var isSpeakingAloud = false {
        didSet {
            if !isSpeakingAloud {
                voice.stop()
            }
        }
    }

    private let assistant: any AssistantReading
    private let voice: any CoachVoice
    private var reader: Task<Void, Never>?
    private var sentences = SentenceBuffer()

    public init(assistant: any AssistantReading, voice: any CoachVoice) {
        self.assistant = assistant
        self.voice = voice
    }

    /// Sends one message and starts streaming the reply.
    ///
    /// Ignored while a reply is streaming — the send affordance is disabled
    /// then, and a race through it would interleave two answers. Stops the
    /// voice first: a new question makes the old answer's remainder noise.
    public func send(_ message: String) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isReplying else { return }

        voice.stop()
        // Only what the server will read: it silently keeps the newest
        // `maxHistoryDepth` turns, so a longer upload is bytes it provably
        // throws away.
        let history = Array(transcript.suffix(ChatTurn.maxHistoryDepth))
        transcript.append(ChatTurn(role: .person, text: message))
        isReplying = true
        sentences = SentenceBuffer()

        // Opened before the task rather than inside it, so the request is in
        // flight the moment send returns and nothing observable races the
        // caller.
        let chunks = assistant.chat(history: history, message: message)

        reader = Task {
            // One identity for the whole reply, fixed before the first chunk,
            // so the row grows rather than being replaced.
            let replyId = UUID()
            var accumulated = ""

            do {
                for try await chunk in chunks where !chunk.text.isEmpty {
                    let grown = ChatTurn(id: replyId, role: .coach, text: accumulated + chunk.text)
                    if accumulated.isEmpty {
                        transcript.append(grown)
                    } else {
                        transcript[transcript.count - 1] = grown
                    }
                    accumulated = grown.text

                    speak(sentences.append(chunk.text))
                }

                if let rest = sentences.flush() {
                    speak([rest])
                }
            } catch {
                // Cancellation is the screen going away, not a failure — and
                // nobody is left to read a quiet sentence either.
                if !(error is CancellationError) {
                    Self.logger.notice(
                        "the reply stopped early: \(error.localizedDescription, privacy: .public)"
                    )
                    if accumulated.isEmpty {
                        transcript.append(ChatTurn(role: .coach, text: Self.unavailableReply))
                    }
                }
            }

            isReplying = false
        }
    }

    /// Stops the stream and the voice. Called when the view goes away, so
    /// neither a request nor a monologue outlives the screen.
    public func cancel() {
        reader?.cancel()
        reader = nil
        voice.stop()
        isReplying = false
    }

    private func speak(_ completed: [String]) {
        guard isSpeakingAloud else { return }
        for sentence in completed {
            voice.speak(sentence)
        }
    }
}

/// Accumulates streamed text and releases it a sentence at a time, so the
/// voice can start on the first sentence while the rest of the reply is still
/// being written.
///
/// A boundary is a sentence terminator (`.` `!` `?` `…`) followed by
/// whitespace, or a newline. Requiring the whitespace is what keeps a decimal
/// ("a 4.7 rhythm") or a mid-number chunk split from ending a sentence early;
/// the cost is that the final sentence of a reply never sees trailing
/// whitespace, which is what [`flush()`](SentenceBuffer.flush) is for.
struct SentenceBuffer {
    private var pending = ""

    /// Adds streamed text and returns the sentences it completed, in order,
    /// trimmed. Chunk boundaries carry no meaning, so a sentence can complete
    /// mid-chunk or span several.
    mutating func append(_ text: String) -> [String] {
        pending += text

        var completed: [String] = []
        while let boundary = firstBoundary() {
            let sentence = String(pending[..<boundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(..<boundary)
            if !sentence.isEmpty {
                completed.append(sentence)
            }
        }
        return completed
    }

    /// The unterminated remainder, trimmed, or nil. Called when the stream
    /// ends: a reply's last sentence is complete by virtue of the stream
    /// ending, whether or not its punctuation ever arrived.
    mutating func flush() -> String? {
        let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return rest.isEmpty ? nil : rest
    }

    /// The index just past the first sentence boundary, or nil while every
    /// sentence is still open.
    private func firstBoundary() -> String.Index? {
        var index = pending.startIndex
        while index < pending.endIndex {
            let character = pending[index]
            let next = pending.index(after: index)

            if character.isNewline {
                return next
            }
            if ".!?…".contains(character), next < pending.endIndex, pending[next].isWhitespace {
                return next
            }
            index = next
        }
        return nil
    }
}
