import BreatheAPI
import Connect
import Foundation

public enum AssistantRepositoryError: LocalizedError, Equatable {
    /// The RPC itself failed — no network, server down, non-OK gRPC status.
    /// Includes `UNAUTHENTICATED`, which is what a call with no readable
    /// Keychain identity comes back as.
    case transport(String)
    /// The response parsed but described something this app cannot represent.
    /// Distinct from `.transport` because retrying will not help: the client and
    /// server contracts have diverged.
    case malformedResponse(String)

    /// Carries the associated message. Without this conformance
    /// `localizedDescription` bridges to a bare `NSError`, and every log line
    /// and failure banner reading it says "The operation couldn't be completed".
    public var errorDescription: String? {
        switch self {
        case let .transport(message): "the request failed: \(message)"
        case let .malformedResponse(message): "the response could not be read: \(message)"
        }
    }
}

/// Reads the assistant's guidance.
///
/// The one type that touches the generated assistant types, mirroring
/// `TechniqueRepository` — everything above it works in `Guidance` and
/// `ExplanationChunk`, so a change to the wire format is a change to this file.
public protocol AssistantReading: Sendable {
    /// Techniques to try next, best first.
    func recommendations() async throws -> Guidance

    /// The explanation, a piece at a time.
    ///
    /// An `AsyncThrowingStream` rather than the Connect interface itself, so
    /// the model above can be written — and tested — against something that
    /// does not need a socket.
    func explanation(of techniqueSlug: String) -> AsyncThrowingStream<ExplanationChunk, Error>
}

public struct AssistantRepository: AssistantReading {
    private let client: Breathe_V1_AssistantServiceClient

    public init(baseURL: URL, identity: any UserIdentityStore) {
        client = BreatheClients.assistantService(baseURL: baseURL, userId: identity.userId)
    }

    public func recommendations() async throws -> Guidance {
        let response = await client
            .getRecommendation(request: Breathe_V1_GetRecommendationRequest())

        guard let message = response.message else {
            throw AssistantRepositoryError.transport(
                response.error?.localizedDescription ?? "the server sent no message"
            )
        }

        guard let source = GuidanceSource(proto: message.source) else {
            throw AssistantRepositoryError.malformedResponse(
                "unrecognised guidance source `\(message.source)`"
            )
        }

        // Total, unlike the technique decoders: both fields are strings the app
        // only displays, and the server has already guaranteed the slug is one
        // the catalogue holds.
        let recommendations = message.recommendations.map {
            Recommendation(techniqueSlug: $0.techniqueSlug, reason: $0.reason)
        }

        guard !recommendations.isEmpty else {
            throw AssistantRepositoryError.malformedResponse("the guidance was empty")
        }

        return Guidance(recommendations: recommendations, source: source)
    }

    /// Bridges the repo's first server stream into an `AsyncThrowingStream`.
    ///
    /// Connect hands back a stream you must `send` the request on exactly once
    /// to start, then read `results()` from. Both halves are wrapped here so
    /// nothing above this file learns that shape — and, more usefully, so the
    /// terminal `.complete` carrying a non-OK code becomes a thrown error
    /// rather than a stream that simply stops, which is indistinguishable from
    /// a short explanation.
    public func explanation(
        of techniqueSlug: String
    ) -> AsyncThrowingStream<ExplanationChunk, Error> {
        AsyncThrowingStream { continuation in
            let stream = client.explainTechnique()

            var request = Breathe_V1_ExplainTechniqueRequest()
            request.techniqueSlug = techniqueSlug

            do {
                try stream.send(request)
            } catch {
                continuation.finish(throwing: AssistantRepositoryError.transport(
                    error.localizedDescription
                ))
                return
            }

            let reader = Task {
                for await result in stream.results() {
                    switch result {
                    case let .message(message):
                        guard let source = GuidanceSource(proto: message.source) else {
                            continuation
                                .finish(throwing: AssistantRepositoryError.malformedResponse(
                                    "unrecognised guidance source `\(message.source)`"
                                ))
                            return
                        }
                        continuation.yield(
                            ExplanationChunk(text: message.text, source: source)
                        )

                    case let .complete(code, error, _):
                        if code == .ok {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: AssistantRepositoryError.transport(
                                error?.localizedDescription ?? "the stream ended with \(code)"
                            ))
                        }
                        return

                    case .headers:
                        continue
                    }
                }

                // The results ran out without a `.complete`, which the library
                // should not do. Finishing rather than hanging keeps the caller
                // total.
                continuation.finish()
            }

            // A view that goes away mid-explanation must not leave the request
            // running: cancelling the read stops the loop, and `cancel()` tells
            // the server to stop writing.
            continuation.onTermination = { _ in
                reader.cancel()
                stream.cancel()
            }
        }
    }
}

extension GuidanceSource {
    /// Returns nil for `UNSPECIFIED` and for any case added after this app
    /// shipped — the same rule every enum on this boundary follows. Guessing
    /// `.fallback` would be the safer-looking default and the wrong one: it
    /// would have the app claim the server said something it did not.
    init?(proto: Breathe_V1_AssistantSource) {
        switch proto {
        case .model: self = .model
        case .fallback: self = .fallback
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }
}
