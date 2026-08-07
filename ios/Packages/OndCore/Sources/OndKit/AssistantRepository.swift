import Connect
import Foundation
import OndAPI

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
/// `AssistantChunk`, so a change to the wire format is a change to this file.
public protocol AssistantReading: Sendable {
    /// Techniques to try next, best first.
    func recommendations() async throws -> Guidance

    /// The explanation, a piece at a time.
    ///
    /// An `AsyncThrowingStream` rather than the Connect interface itself, so
    /// the model above can be written — and tested — against something that
    /// does not need a socket.
    func explanation(of techniqueSlug: String) -> AsyncThrowingStream<AssistantChunk, Error>

    /// The coach's reply to one message, a piece at a time.
    ///
    /// `history` is the transcript so far, oldest first, and the new message
    /// rides separately — the server keeps no conversation state, so every
    /// call carries what the coach should remember. Same stream shape as
    /// `explanation(of:)`, for the same testability reason.
    func chat(history: [ChatTurn], message: String) -> AsyncThrowingStream<AssistantChunk, Error>
}

public struct AssistantRepository: AssistantReading {
    private let client: Ond_V1_AssistantServiceClient
    private let healthContext: @Sendable () async -> CoachHealthContext?

    /// `healthContext` is asked immediately before each request and its answer
    /// attached to that request alone — never cached here, because the person
    /// can withdraw the opt-in between two calls and the very next request
    /// must already carry nothing. The default provider answers nil, which is
    /// a request identical to one from a build that predates health context.
    public init(
        baseURL: URL,
        identity: any UserIdentityStore,
        healthContext: @escaping @Sendable () async -> CoachHealthContext? = { nil }
    ) {
        client = OndClients.assistantService(baseURL: baseURL, userId: identity.userId)
        self.healthContext = healthContext
    }

    public func recommendations() async throws -> Guidance {
        var request = Ond_V1_GetRecommendationRequest()
        if let context = await healthContext() {
            request.healthContext = Self.wire(context)
        }
        let response = await client.getRecommendation(request: request)

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

    public func explanation(
        of techniqueSlug: String
    ) -> AsyncThrowingStream<AssistantChunk, Error> {
        bridged(client.explainTechnique(), request: { [healthContext] in
            var request = Ond_V1_ExplainTechniqueRequest()
            request.techniqueSlug = techniqueSlug
            if let context = await healthContext() {
                request.healthContext = Self.wire(context)
            }
            return request
        }, chunk: { Self.chunk(text: $0.text, source: $0.source) })
    }

    public func chat(
        history: [ChatTurn],
        message: String
    ) -> AsyncThrowingStream<AssistantChunk, Error> {
        bridged(client.chat(), request: { [healthContext] in
            var request = Ond_V1_ChatRequest()
            request.history = history.map(Self.wire)
            request.message = message
            if let context = await healthContext() {
                request.healthContext = Self.wire(context)
            }
            return request
        }, chunk: { Self.chunk(text: $0.text, source: $0.source) })
    }

    /// Bridges one Connect server stream into an `AsyncThrowingStream` —
    /// written once because the subtle parts must not be able to drift
    /// between RPCs.
    ///
    /// Connect hands back a stream you must `send` the request on exactly once
    /// to start, then read `results()` from. Both halves are wrapped here so
    /// nothing above this file learns that shape — and, more usefully, so the
    /// terminal `.complete` carrying a non-OK code becomes a thrown error
    /// rather than a stream that simply stops, which is indistinguishable from
    /// a short answer.
    ///
    /// The request is built *inside* the reader task, because the health
    /// provider it awaits is async and the stream closure cannot suspend —
    /// the summary is read from Health at the moment of the request.
    private func bridged<Request, Response>(
        _ stream: any ServerOnlyAsyncStreamInterface<Request, Response>,
        request: @escaping @Sendable () async -> Request,
        chunk: @escaping @Sendable (Response) -> Result<AssistantChunk, AssistantRepositoryError>
    ) -> AsyncThrowingStream<AssistantChunk, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    try await stream.send(request())
                } catch {
                    continuation.finish(throwing: AssistantRepositoryError.transport(
                        error.localizedDescription
                    ))
                    return
                }

                for await result in stream.results() {
                    switch result {
                    case let .message(message):
                        switch chunk(message) {
                        case let .success(chunk):
                            continuation.yield(chunk)
                        case let .failure(error):
                            continuation.finish(throwing: error)
                            return
                        }

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

            // A view that goes away mid-answer must not leave the request
            // running: cancelling the read stops the loop, and `cancel()` tells
            // the server to stop writing.
            continuation.onTermination = { _ in
                reader.cancel()
                stream.cancel()
            }
        }
    }

    /// One wire chunk as the domain chunk, or the refusal every enum on this
    /// boundary earns — an unrepresentable source is a decode failure, never
    /// a guess.
    private static func chunk(
        text: String,
        source proto: Ond_V1_AssistantSource
    ) -> Result<AssistantChunk, AssistantRepositoryError> {
        guard let source = GuidanceSource(proto: proto) else {
            return .failure(.malformedResponse("unrecognised guidance source `\(proto)`"))
        }
        return .success(AssistantChunk(text: text, source: source))
    }

    /// The domain turn as the wire message. Total in this direction: every
    /// domain role has a wire value, so nothing the app holds can fail to be
    /// read back.
    private static func wire(_ turn: ChatTurn) -> Ond_V1_ChatTurn {
        var wire = Ond_V1_ChatTurn()
        wire.role =
            switch turn.role {
            case .person: .person
            case .coach: .coach
            }
        wire.text = turn.text
        return wire
    }

    /// The domain summary as the wire message, metric by metric. A snapshot's
    /// nil trend stays an absent field — the server reads absence as "too
    /// little evidence", which is exactly what it was. `clamping` because the
    /// values are whole-unit physiological means: anything an `Int32` cannot
    /// hold is a corrupt reading, and the server's range clamp drops it there.
    private static func wire(_ context: CoachHealthContext) -> Ond_V1_HealthContext {
        var wire = Ond_V1_HealthContext()
        if let resting = context.restingHeartRate {
            wire.restingHrBpm = Int32(clamping: resting.sevenDayMean)
            if let trend = resting.trendFromBaseline {
                wire.restingHrTrendBpm = Int32(clamping: trend)
            }
        }
        if let variability = context.heartRateVariability {
            wire.hrvSdnnMs = Int32(clamping: variability.sevenDayMean)
            if let trend = variability.trendFromBaseline {
                wire.hrvSdnnTrendMs = Int32(clamping: trend)
            }
        }
        return wire
    }
}

extension GuidanceSource {
    /// Returns nil for `UNSPECIFIED` and for any case added after this app
    /// shipped — the same rule every enum on this boundary follows. Guessing
    /// `.fallback` would be the safer-looking default and the wrong one: it
    /// would have the app claim the server said something it did not.
    init?(proto: Ond_V1_AssistantSource) {
        switch proto {
        case .model: self = .model
        case .fallback: self = .fallback
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }
}
