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

/// Reads the technique catalogue.
///
/// This is the only type that touches generated protobuf types. Everything above
/// it works in `Technique`, so a change to the wire format is a change to this
/// file rather than to every view that displays one.
public protocol TechniqueReading: Sendable {
    func listTechniques() async throws -> [Technique]
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
}

extension Technique {
    init(proto: Breathe_V1_Technique) throws {
        guard let goal = TechniqueGoal(proto: proto.goal) else {
            throw TechniqueRepositoryError.malformedResponse(
                "technique `\(proto.slug)` has unrecognised goal `\(proto.goal)`"
            )
        }

        guard !proto.phases.isEmpty else {
            throw TechniqueRepositoryError.malformedResponse(
                "technique `\(proto.slug)` has no phases"
            )
        }

        try self.init(
            id: proto.id,
            slug: proto.slug,
            name: proto.name,
            summary: proto.summary,
            goal: goal,
            phases: proto.phases.map(Phase.init(proto:))
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

        self.init(kind: kind, duration: .milliseconds(proto.durationMs))
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
