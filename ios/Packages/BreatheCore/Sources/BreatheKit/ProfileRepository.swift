import BreatheAPI
import Foundation

public enum ProfileRepositoryError: Error, Equatable {
    /// The RPC itself failed — no network, server down, non-OK gRPC status.
    /// Includes `UNAUTHENTICATED`, which is what a call with no readable
    /// Keychain identity comes back as.
    case transport(String)
    /// The response parsed but described something this app cannot represent.
    /// Distinct from `.transport` because retrying will not help: the client and
    /// server contracts have diverged.
    case malformedResponse(String)
}

/// Reads and writes the answers someone gave at onboarding.
///
/// This is the only type that touches the generated profile types, mirroring
/// `TechniqueReading`. Split into two protocols because the consumers differ:
/// onboarding only ever writes, and splitting keeps its test double to one
/// function.
public protocol ProfileReading: Sendable {
    func profile() async throws -> Profile
}

public protocol ProfileWriting: Sendable {
    /// Stores `profile` and returns it as the server holds it, which is not
    /// always what was sent — the server drops a duplicated goal and trims the
    /// note.
    @discardableResult
    func update(_ profile: Profile) async throws -> Profile
}

public struct ProfileRepository: ProfileReading, ProfileWriting {
    private let client: Breathe_V1_ProfileServiceClient

    public init(baseURL: URL, identity: any UserIdentityStore) {
        client = BreatheClients.profileService(baseURL: baseURL, userId: identity.userId)
    }

    public func profile() async throws -> Profile {
        let response = await client.getProfile(request: Breathe_V1_GetProfileRequest())

        guard let message = response.message else {
            throw ProfileRepositoryError.transport(
                response.error?.localizedDescription ?? "the request failed with no message"
            )
        }

        return try Profile(proto: message.profile)
    }

    @discardableResult
    public func update(_ profile: Profile) async throws -> Profile {
        var request = Breathe_V1_UpdateProfileRequest()
        request.profile = profile.proto

        let response = await client.updateProfile(request: request)

        guard let message = response.message else {
            throw ProfileRepositoryError.transport(
                response.error?.localizedDescription ?? "the request failed with no message"
            )
        }

        return try Profile(proto: message.profile)
    }
}

extension Profile {
    init(proto: Breathe_V1_Profile) throws {
        // A goal this app has no case for is a decode failure rather than a gap
        // in the list: silently shortening someone's goals gives them back a
        // profile they did not choose and cannot tell apart from one they did.
        let goals = try proto.goals.map { raw in
            guard let goal = TechniqueGoal(proto: raw) else {
                throw ProfileRepositoryError.malformedResponse(
                    "unrecognised goal `\(raw)`"
                )
            }
            return goal
        }

        guard let reminderIntensity = ReminderIntensity(proto: proto.reminderIntensity) else {
            throw ProfileRepositoryError.malformedResponse(
                "unrecognised reminder intensity `\(proto.reminderIntensity)`"
            )
        }

        try self.init(
            goals: goals,
            experienceLevel: ExperienceLevel(proto: proto.experienceLevel),
            reminderIntensity: reminderIntensity,
            intentNote: proto.intentNote
        )
    }

    var proto: Breathe_V1_Profile {
        var message = Breathe_V1_Profile()
        message.goals = goals.map(\.proto)
        message.experienceLevel = experienceLevel?.proto ?? .unspecified
        message.reminderIntensity = reminderIntensity.proto
        message.intentNote = intentNote
        return message
    }
}

extension ExperienceLevel {
    /// Throws on a level added to the proto after this app shipped, and returns
    /// nil for `unspecified` — which is not a failure but the honest answer to a
    /// question nobody has been asked yet.
    init?(proto: Breathe_V1_ExperienceLevel) throws {
        switch proto {
        case .new: self = .new
        case .occasional: self = .occasional
        case .regular: self = .regular
        case .unspecified: return nil
        case .UNRECOGNIZED:
            throw ProfileRepositoryError.malformedResponse(
                "unrecognised experience level `\(proto)`"
            )
        }
    }

    var proto: Breathe_V1_ExperienceLevel {
        switch self {
        case .new: .new
        case .occasional: .occasional
        case .regular: .regular
        }
    }
}

extension ReminderIntensity {
    /// Returns nil only for a value this app has no case for. `never` is a real
    /// case here rather than the boundary's failure state, because it is the
    /// proto's zero value — an unset field, an older server, and a truncated
    /// write all have to arrive as silence.
    init?(proto: Breathe_V1_ReminderIntensity) {
        switch proto {
        case .never: self = .never
        case .gentle: self = .gentle
        case .daily: self = .daily
        case .UNRECOGNIZED: return nil
        }
    }

    var proto: Breathe_V1_ReminderIntensity {
        switch self {
        case .never: .never
        case .gentle: .gentle
        case .daily: .daily
        }
    }
}

extension TechniqueGoal {
    var proto: Breathe_V1_TechniqueGoal {
        switch self {
        case .calm: .calm
        case .sleep: .sleep
        case .energy: .energy
        case .reset: .reset
        case .focus: .focus
        }
    }
}
