import BreatheAPI
import Foundation

public enum ProfileRepositoryError: Error, Equatable {
    /// The RPC failed on something a later attempt may not hit — no network, a
    /// server that is down, a status this client can only wait out. Includes
    /// `UNAUTHENTICATED`, which is what a call with no readable Keychain
    /// identity comes back as, and which the next launch may well fix.
    case transport(String)
    /// The server refused these answers themselves, and would refuse them again.
    ///
    /// Split from `.transport` because it is the one failure retrying cannot
    /// mend: a profile left pending on an `INVALID_ARGUMENT` re-attempts on
    /// every cold launch for the life of the install, while the screen that sent
    /// it reads the refused value back and shows it as saved. Carries the
    /// server's own message, which names what it objected to.
    case rejected(String)
    /// The response parsed but described something this app cannot represent.
    /// Distinct from `.transport` because retrying will not help: the client and
    /// server contracts have diverged.
    case malformedResponse(String)
}

/// Carries the answers someone gave at onboarding, in both directions.
///
/// This device is the source of truth while somebody is using it, but the
/// Keychain identity outlives an install and the sessions file does not — so on
/// a launch that has no local answers the server may still hold them. That is
/// the only thing the read is for; see `ProfileStore.restoredProfile()`.
public protocol ProfileSyncing: Sendable {
    /// The profile as the server holds it.
    ///
    /// Never a not-found: the identity layer creates the row on first sight, so
    /// a caller who has answered nothing reads back `Profile.unanswered` rather
    /// than an error to special-case.
    func fetch() async throws -> Profile

    /// Stores `profile` and returns it as the server holds it, which is not
    /// always what was sent — the server drops a duplicated goal and trims the
    /// note.
    @discardableResult
    func update(_ profile: Profile) async throws -> Profile
}

/// The only type that touches the generated profile types, mirroring
/// `TechniqueRepository`.
public struct ProfileRepository: ProfileSyncing {
    private let client: Breathe_V1_ProfileServiceClient

    public init(baseURL: URL, identity: any UserIdentityStore) {
        client = BreatheClients.profileService(baseURL: baseURL, userId: identity.userId)
    }

    public func fetch() async throws -> Profile {
        let response = await client.getProfile(request: Breathe_V1_GetProfileRequest())

        guard let message = response.message else {
            throw Self.failure(refused: response.code == .invalidArgument, response.error)
        }

        return try Profile(proto: message.profile)
    }

    @discardableResult
    public func update(_ profile: Profile) async throws -> Profile {
        var request = Breathe_V1_UpdateProfileRequest()
        request.profile = profile.proto

        let response = await client.updateProfile(request: request)

        guard let message = response.message else {
            throw Self.failure(refused: response.code == .invalidArgument, response.error)
        }

        return try Profile(proto: message.profile)
    }

    /// The one distinction a caller acts on: whether waiting could ever change
    /// the answer.
    ///
    /// The status arrives as a flag rather than as a `Code` for the reason
    /// `JourneyRepository.failure` gives: Connect is BreatheAPI's dependency and
    /// not this target's. A `nil` error under a `nil` message would be a library
    /// invariant violation, so the fallback text exists only to keep this total.
    private static func failure(
        refused: Bool,
        _ error: (any Error)?
    ) -> ProfileRepositoryError {
        let message = error?.localizedDescription ?? "the request failed with no message"
        return refused ? .rejected(message) : .transport(message)
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
            experienceLevel: ExperienceLevel.decoded(from: proto.experienceLevel),
            reminderIntensity: reminderIntensity,
            intentNote: proto.intentNote,
            displayName: proto.displayName,
            birthYearBand: BirthYearBand.decoded(from: proto.birthYearBand)
        )
    }

    var proto: Breathe_V1_Profile {
        var message = Breathe_V1_Profile()
        message.goals = goals.map(\.proto)
        message.experienceLevel = experienceLevel?.proto ?? .unspecified
        message.reminderIntensity = reminderIntensity.proto
        message.intentNote = intentNote
        message.displayName = displayName
        message.birthYearBand = birthYearBand?.proto ?? .unspecified
        return message
    }
}

extension BirthYearBand {
    /// Two non-answers, one initialiser cannot report both — the same shape as
    /// `ExperienceLevel.decoded(from:)`: `nil` means they did not say, and
    /// throwing means a band added to the proto after this app shipped.
    static func decoded(from proto: Breathe_V1_BirthYearBand) throws -> Self? {
        switch proto {
        case .bornBefore1960: .before1960
        case .born1960S: .sixties
        case .born1970S: .seventies
        case .born1980S: .eighties
        case .born1990S: .nineties
        case .born2000S: .noughties
        case .born2010OrLater: .twentyTensOrLater
        case .unspecified: nil
        case .UNRECOGNIZED:
            throw ProfileRepositoryError.malformedResponse(
                "unrecognised birth year band `\(proto)`"
            )
        }
    }

    var proto: Breathe_V1_BirthYearBand {
        switch self {
        case .before1960: .bornBefore1960
        case .sixties: .born1960S
        case .seventies: .born1970S
        case .eighties: .born1980S
        case .nineties: .born1990S
        case .noughties: .born2000S
        case .twentyTensOrLater: .born2010OrLater
        }
    }
}

extension ExperienceLevel {
    /// Not an `init?(proto:)` like its neighbours, because this field has two
    /// distinct non-answers and one initialiser cannot report both: `nil` means
    /// nobody has been asked, and throwing means a level added to the proto
    /// after this app shipped.
    static func decoded(from proto: Breathe_V1_ExperienceLevel) throws -> Self? {
        switch proto {
        case .new: .new
        case .occasional: .occasional
        case .regular: .regular
        case .unspecified: nil
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
