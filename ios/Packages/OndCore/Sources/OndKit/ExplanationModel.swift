import Foundation
import Observation
import os

/// Accumulates a streamed explanation into text a view can render as it grows.
///
/// The whole reason the RPC streams: `text` is republished on every chunk, so
/// SwiftUI redraws the paragraph as it is written rather than after. A model
/// that collected the stream and published once would have the same code and
/// none of the point.
@MainActor
@Observable
public final class ExplanationModel {
    public enum State: Equatable, Sendable {
        /// Nothing asked for yet — the disclosure is closed.
        case idle
        /// Asked, nothing back yet.
        case waiting
        /// Text so far. `isComplete` is false while more is coming *and* when
        /// the stream died part-way through, which is what stops a view
        /// captioning half a paragraph as a finished answer.
        case reading(text: String, source: GuidanceSource, isComplete: Bool)
        /// The stream never started or died before its first chunk. Deliberately
        /// carries no message: there is nothing the reader can do about it, and
        /// a technical string in a calm screen is worse than a quiet sentence.
        case unavailable
    }

    private static let logger = Logger(category: "assistant")

    public private(set) var state: State = .idle

    private let assistant: any AssistantReading
    private let techniqueSlug: String
    private var reader: Task<Void, Never>?

    public init(assistant: any AssistantReading, techniqueSlug: String) {
        self.assistant = assistant
        self.techniqueSlug = techniqueSlug
    }

    /// Starts the explanation, or does nothing if it has already been asked for.
    ///
    /// Idempotent because the view calls it from `.task` and from the
    /// disclosure's toggle, and asking twice would spend two of the day's
    /// allowance on one paragraph.
    public func startIfNeeded() {
        guard case .idle = state else { return }
        start()
    }

    private func start() {
        reader?.cancel()
        state = .waiting

        reader = Task { [assistant, techniqueSlug] in
            var accumulated = ""
            var source: GuidanceSource?
            var isComplete = true

            do {
                for try await chunk in assistant.explanation(of: techniqueSlug) {
                    accumulated += chunk.text
                    source = chunk.source
                    state = .reading(text: accumulated, source: chunk.source, isComplete: false)
                }
            } catch {
                isComplete = false
                // Cancellation is the disclosure closing under a live stream,
                // not a failure, and nobody is left to read the log line.
                if !(error is CancellationError) {
                    Self.logger
                        .notice(
                            "the explanation stopped early: \(error.localizedDescription, privacy: .public)"
                        )
                }
            }

            // Half an explanation is still worth reading; nothing at all is the
            // one case the view renders a placeholder for. A stream that broke
            // and one that finished land in the same case, so the "keep what
            // arrived" rule is written once — only the caption differs.
            guard let source, !accumulated.isEmpty else {
                state = .unavailable
                return
            }
            state = .reading(text: accumulated, source: source, isComplete: isComplete)
        }
    }

    /// Stops reading. Called when the view goes away, so a stream nobody is
    /// watching does not keep the request open.
    public func cancel() {
        reader?.cancel()
        reader = nil
    }
}
