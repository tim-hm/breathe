import Foundation
import OndAPI

public enum UserTechniqueRepositoryError: LocalizedError, Equatable {
    /// The RPC failed on something a later attempt may not hit — no network, a
    /// server that is down, an `UNAUTHENTICATED` a Keychain read may yet fix.
    case transport(String)
    /// The server refused this draft and would refuse it again: a phase outside
    /// the seeded safe range, or one exercise more than a person may keep.
    ///
    /// Split from `.transport` for the reason `ProfileRepositoryError.rejected`
    /// is — retrying cannot mend it — and carries the server's own message,
    /// which names the phase it objected to.
    case rejected(String)
    /// The response parsed but described something this app cannot represent.
    case malformedResponse(String)

    /// Carries the associated message. Without this conformance
    /// `localizedDescription` bridges to a bare `NSError`, and every log line
    /// and failure banner reading it says "The operation couldn't be completed".
    public var errorDescription: String? {
        switch self {
        case let .transport(message): "the request failed: \(message)"
        case let .rejected(message): message
        case let .malformedResponse(message): "the response could not be read: \(message)"
        }
    }
}

/// One person's exercises, and the limits they may be composed within.
///
/// The limits travel with the list rather than being fetched separately: a
/// composer needs them before there is anything to list, which is exactly the
/// first launch this call covers.
public struct UserTechniqueList: Sendable, Equatable, Codable {
    public let techniques: [Technique]
    public let limits: AuthoringLimits

    public init(techniques: [Technique], limits: AuthoringLimits) {
        self.techniques = techniques
        self.limits = limits
    }
}

/// Reads and writes the exercises somebody composed for themselves.
///
/// The counterpart to `TechniqueReading`, kept separate for the reason the two
/// services are: one is reference data anybody may read, the other is one
/// person's own and needs their identity on every call.
public protocol UserTechniqueStoring: Sendable {
    func listUserTechniques() async throws -> UserTechniqueList
    func createUserTechnique(_ draft: TechniqueDraft) async throws -> Technique
    func updateUserTechnique(id: String, to draft: TechniqueDraft) async throws -> Technique
    func deleteUserTechnique(id: String) async throws
}

/// The only type that touches the generated user-technique types, mirroring
/// `TechniqueRepository`.
public struct UserTechniqueRepository: UserTechniqueStoring {
    private let client: Ond_V1_UserTechniqueServiceClient

    public init(baseURL: URL, identity: any UserIdentityStore) {
        client = OndClients.userTechniqueService(baseURL: baseURL, userId: identity.userId)
    }

    public func listUserTechniques() async throws -> UserTechniqueList {
        let response = await client
            .listUserTechniques(request: Ond_V1_ListUserTechniquesRequest())

        guard let message = response.message else {
            throw Self.failure(refused: false, response.error)
        }

        guard message.hasLimits else {
            throw UserTechniqueRepositoryError.malformedResponse(
                "the server sent no authoring limits"
            )
        }

        return try UserTechniqueList(
            techniques: message.techniques.map(Technique.init(authored:)),
            limits: AuthoringLimits(proto: message.limits)
        )
    }

    public func createUserTechnique(_ draft: TechniqueDraft) async throws -> Technique {
        var request = Ond_V1_CreateUserTechniqueRequest()
        request.draft = draft.proto

        let response = await client.createUserTechnique(request: request)

        guard let message = response.message else {
            // The two ways a create is refused rather than merely failed: a
            // phase outside the seeded safe range, and one exercise past the
            // number a person may keep.
            let refused = response.code == .invalidArgument
                || response.code == .resourceExhausted
            throw Self.failure(refused: refused, response.error)
        }

        return try Technique(authored: message.technique)
    }

    public func updateUserTechnique(id: String, to draft: TechniqueDraft) async throws -> Technique {
        var request = Ond_V1_UpdateUserTechniqueRequest()
        request.id = id
        request.draft = draft.proto

        let response = await client.updateUserTechnique(request: request)

        guard let message = response.message else {
            // `notFound` is a refusal rather than a fault: the exercise was
            // deleted on another device, and retrying reaches for a row that
            // will never come back.
            let refused = response.code == .invalidArgument || response.code == .notFound
            throw Self.failure(refused: refused, response.error)
        }

        return try Technique(authored: message.technique)
    }

    /// Deleting is idempotent server-side, so there is no refusal to
    /// distinguish: an exercise that was already gone comes back as success.
    public func deleteUserTechnique(id: String) async throws {
        var request = Ond_V1_DeleteUserTechniqueRequest()
        request.id = id

        let response = await client.deleteUserTechnique(request: request)

        guard response.message != nil else {
            throw Self.failure(refused: false, response.error)
        }
    }

    /// The status arrives as a flag rather than as a `Code` for the reason
    /// `ProfileRepository.failure` gives: Connect is OndAPI's dependency and not
    /// this target's. A nil error under a nil message would be a library
    /// invariant violation, so the fallback text exists only to keep this total.
    private static func failure(
        refused: Bool,
        _ error: (any Error)?
    ) -> UserTechniqueRepositoryError {
        let message = error?.localizedDescription ?? "the server sent no message"
        return refused ? .rejected(message) : .transport(message)
    }
}

extension Technique {
    /// The same decoding as a catalogue technique, stamped `.personal`.
    ///
    /// Routed through `init(proto:)` rather than repeated, because every
    /// invariant that decoder enforces — non-empty stages, a phase inside its
    /// own range — is an invariant `SessionTimeline` depends on, and an authored
    /// exercise plays through the same one.
    init(authored proto: Ond_V1_Technique) throws {
        try self.init(proto: proto, origin: .personal)
    }
}

extension TechniqueDraft {
    var proto: Ond_V1_TechniqueDraft {
        var message = Ond_V1_TechniqueDraft()
        message.name = name
        message.goal = goal.proto
        message.rounds = UInt32(clamping: rounds)
        message.stages = stages.map { stage in
            var draft = Ond_V1_DraftStage()
            draft.cycles = UInt32(clamping: stage.cycles)
            draft.phases = stage.phases.map { phase in
                var draft = Ond_V1_DraftPhase()
                draft.kind = phase.kind.proto
                draft.durationMs = UInt32(clamping: phase.duration.milliseconds)
                return draft
            }
            return draft
        }
        return message
    }
}

extension AuthoringLimits {
    init(proto: Ond_V1_AuthoringLimits) throws {
        // Every count is a floor of one that the contract leaves uncarried, so a
        // server sending zero is one this client cannot compose against at all —
        // a stepper with an empty range traps rather than degrades.
        guard proto.maxNameChars >= 1,
              proto.maxStages >= 1,
              proto.maxPhasesPerStage >= 1,
              proto.maxCycles >= 1,
              proto.maxRounds >= 1,
              proto.maxTechniques >= 1
        else {
            throw UserTechniqueRepositoryError.malformedResponse(
                "the authoring limits leave nothing to compose"
            )
        }

        try self.init(
            phases: proto.phases.map(PhaseLimit.init(proto:)),
            maxNameChars: Int(proto.maxNameChars),
            maxStages: Int(proto.maxStages),
            maxPhasesPerStage: Int(proto.maxPhasesPerStage),
            cycleRange: 1 ... Int(proto.maxCycles),
            roundRange: 1 ... Int(proto.maxRounds),
            maxTechniques: Int(proto.maxTechniques)
        )
    }
}

extension PhaseLimit {
    init(proto: Ond_V1_PhaseLimit) throws {
        guard let kind = PhaseKind(proto: proto.kind) else {
            throw UserTechniqueRepositoryError.malformedResponse(
                "unrecognised phase kind `\(proto.kind)`"
            )
        }

        // A dial rendered from an inverted range has nowhere to put its handle,
        // and `ClosedRange` traps on one rather than emptying.
        guard proto.minDurationMs > 0, proto.minDurationMs <= proto.maxDurationMs else {
            throw UserTechniqueRepositoryError.malformedResponse(
                "the \(kind) limit is \(proto.minDurationMs)–\(proto.maxDurationMs)ms"
            )
        }

        self.init(
            kind: kind,
            range: .milliseconds(proto.minDurationMs) ... .milliseconds(proto.maxDurationMs)
        )
    }
}
