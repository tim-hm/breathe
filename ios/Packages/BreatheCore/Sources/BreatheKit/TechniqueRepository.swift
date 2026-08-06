import BreatheAPI
import Foundation

public enum TechniqueRepositoryError: Error, Equatable {
    /// The RPC itself failed — no network, server down, non-OK gRPC status.
    case transport(String)
    /// The response parsed but described something this app cannot represent,
    /// such as a goal it has no case for. Distinct from `.transport` because
    /// retrying will not help: the client and server contracts have diverged.
    case malformedResponse(String)
}

/// Reads the technique catalogue and the breathing foundations.
///
/// This is the only type that touches generated protobuf types. Everything above
/// it works in `Technique`, so a change to the wire format is a change to this
/// file rather than to every view that displays one.
public protocol TechniqueReading: Sendable {
    func listTechniques() async throws -> [Technique]
    func listFoundations() async throws -> [FoundationTopic]
}

public struct TechniqueRepository: TechniqueReading {
    private let client: Breathe_V1_TechniqueServiceClient

    public init(baseURL: URL) {
        client = BreatheClients.techniqueService(baseURL: baseURL)
    }

    public func listTechniques() async throws -> [Technique] {
        let response = await client.listTechniques(request: Breathe_V1_ListTechniquesRequest())

        guard let message = response.message else {
            // `ResponseMessage` carries either a message or an error; a nil
            // message with no error would be a library invariant violation, so
            // the fallback text exists only to keep this total.
            throw TechniqueRepositoryError.transport(
                response.error?.localizedDescription ?? "the request failed with no message"
            )
        }

        return try message.techniques.map(Technique.init(proto:))
    }

    public func listFoundations() async throws -> [FoundationTopic] {
        let response = await client.listFoundations(request: Breathe_V1_ListFoundationsRequest())

        guard let message = response.message else {
            throw TechniqueRepositoryError.transport(
                response.error?.localizedDescription ?? "the request failed with no message"
            )
        }

        return message.topics.map(FoundationTopic.init(proto:))
    }
}

extension Technique {
    init(proto: Breathe_V1_Technique) throws {
        guard let goal = TechniqueGoal(proto: proto.goal) else {
            throw TechniqueRepositoryError.malformedResponse(
                "technique `\(proto.slug)` has unrecognised goal `\(proto.goal)`"
            )
        }

        guard !proto.stages.isEmpty else {
            throw TechniqueRepositoryError.malformedResponse(
                "technique `\(proto.slug)` has no stages"
            )
        }

        // Zero is the proto default, so it is what a server that predates the
        // field sends. Treating it as a decode failure rather than substituting
        // a guess keeps the same rule the enums follow: a value this app cannot
        // represent — and a session of no rounds is one — never becomes a
        // silent default.
        guard proto.recommendedRounds >= 1 else {
            throw TechniqueRepositoryError.malformedResponse(
                "technique `\(proto.slug)` recommends no rounds"
            )
        }

        try self.init(
            id: proto.id,
            slug: proto.slug,
            name: proto.name,
            summary: proto.summary,
            goal: goal,
            stages: proto.stages.map { try Stage(proto: $0, slug: proto.slug) },
            recommendedRounds: Int(proto.recommendedRounds),
            // Empty is how the contract says "nothing to warn about", and an
            // empty caution rendered as one would be worse than none.
            safetyNote: proto.safetyNote.isEmpty ? nil : proto.safetyNote
        )
    }
}

extension Stage {
    /// Takes the technique's slug only to name it in a failure — a stage has no
    /// identity of its own beyond its position.
    init(proto: Breathe_V1_Stage, slug: String) throws {
        guard !proto.phases.isEmpty else {
            throw TechniqueRepositoryError.malformedResponse(
                "technique `\(slug)` has a stage with no phases"
            )
        }

        guard proto.cycles >= 1 else {
            throw TechniqueRepositoryError.malformedResponse(
                "technique `\(slug)` has a stage playing no cycles"
            )
        }

        try self.init(
            phases: proto.phases.map(Phase.init(proto:)),
            cycles: Int(proto.cycles),
            openEnded: proto.openEnded
        )
    }
}

extension Phase {
    init(proto: Breathe_V1_Phase) throws {
        guard let kind = PhaseKind(proto: proto.kind) else {
            throw TechniqueRepositoryError.malformedResponse(
                "unrecognised phase kind `\(proto.kind)`"
            )
        }

        // The dial is rendered from this range, so a range that does not contain
        // its own default leaves a slider with nowhere to put the handle. Same
        // rule as everywhere else on this boundary: reject rather than repair,
        // because a repaired range is a safe limit this app invented.
        guard proto.minDurationMs > 0,
              proto.minDurationMs <= proto.durationMs,
              proto.durationMs <= proto.maxDurationMs
        else {
            throw TechniqueRepositoryError.malformedResponse(
                "a \(proto.durationMs)ms phase sits outside its "
                    + "\(proto.minDurationMs)–\(proto.maxDurationMs)ms range"
            )
        }

        self.init(
            kind: kind,
            duration: .milliseconds(proto.durationMs),
            range: .milliseconds(proto.minDurationMs) ... .milliseconds(proto.maxDurationMs)
        )
    }
}

extension FoundationTopic {
    /// Total, unlike the technique decoders: every field is a string this app
    /// only ever displays, so there is no value here it could fail to represent.
    init(proto: Breathe_V1_FoundationTopic) {
        self.init(slug: proto.slug, question: proto.question, answer: proto.answer)
    }
}

extension TechniqueGoal {
    /// Returns nil for `UNSPECIFIED` and for any case added to the proto after
    /// this app shipped — both mean the same thing to a running client, and both
    /// must be a decode failure rather than a silent default.
    init?(proto: Breathe_V1_TechniqueGoal) {
        switch proto {
        case .calm: self = .calm
        case .sleep: self = .sleep
        case .energy: self = .energy
        case .reset: self = .reset
        case .focus: self = .focus
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }
}

extension PhaseKind {
    init?(proto: Breathe_V1_PhaseKind) {
        switch proto {
        case .inhale: self = .inhale
        case .holdIn: self = .holdIn
        case .exhale: self = .exhale
        case .holdOut: self = .holdOut
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }
}
