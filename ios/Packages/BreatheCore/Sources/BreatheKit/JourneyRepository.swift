import BreatheAPI
import Foundation

public enum JourneyRepositoryError: Error, Equatable {
    /// The RPC itself failed — no network, server down, non-OK gRPC status.
    /// Everything the journey does over the network is optional, so a caller's
    /// correct response is almost always to try again later.
    case transport(String)
    /// The response parsed but described something this app cannot represent.
    /// Distinct from `.transport` because retrying will not help: the client and
    /// server contracts have diverged.
    case malformedResponse(String)
}

/// What the server made of a batch of sessions.
public struct SessionSyncResult: Sendable, Equatable {
    /// Sessions it had not seen before.
    public let recorded: Int
    /// Sessions it already held. Not a failure — it is the expected answer to a
    /// resend, which is the whole reason each session carries an id.
    public let alreadyKnown: Int
}

/// The network side of the journey.
///
/// Everything here is a sync or a genuinely online read. Nothing the journey tab
/// draws about *this person* goes through it — totals, streaks, and the personal
/// best are folded from the local stores, so the tab is complete with the radio
/// off. Leaderboards are the honest exception: they are other people, and other
/// people need a connection.
public protocol JourneySyncing: Sendable {
    /// Sends sessions the server may not have. Idempotent on each session's id,
    /// so a caller unsure of what landed may simply send it again.
    @discardableResult
    func record(_ sessions: [SessionRecord]) async throws -> SessionSyncResult

    /// Sends one controlled-pause score.
    func record(_ score: BoltScore) async throws

    /// The sessions the server holds — the restore path after a reinstall, where
    /// the Keychain identity outlived the local file.
    func storedSessions() async throws -> [SessionRecord]

    func leaderboard(_ board: LeaderboardBoard, scope: LeaderboardScope) async throws -> Leaderboard
}

/// The only type that touches the generated journey types, mirroring
/// `TechniqueRepository` and `ProfileRepository`.
public struct JourneyRepository: JourneySyncing {
    private let client: Breathe_V1_JourneyServiceClient

    public init(baseURL: URL, identity: any UserIdentityStore) {
        client = BreatheClients.journeyService(baseURL: baseURL, userId: identity.userId)
    }

    @discardableResult
    public func record(_ sessions: [SessionRecord]) async throws -> SessionSyncResult {
        var request = Breathe_V1_RecordSessionsRequest()
        request.sessions = sessions.map(\.proto)

        let response = await client.recordSessions(request: request)
        guard let message = response.message else {
            throw Self.transportError(response.error)
        }

        return SessionSyncResult(
            recorded: Int(message.recorded),
            alreadyKnown: Int(message.alreadyKnown)
        )
    }

    public func record(_ score: BoltScore) async throws {
        var request = Breathe_V1_RecordBoltScoreRequest()
        request.seconds = UInt32(max(0, score.seconds))
        let measured = timestampParts(score.measuredAt)
        request.measuredAt.seconds = measured.seconds
        request.measuredAt.nanos = measured.nanos

        let response = await client.recordBoltScore(request: request)
        guard response.message != nil else {
            throw Self.transportError(response.error)
        }
    }

    public func storedSessions() async throws -> [SessionRecord] {
        var request = Breathe_V1_GetJourneyRequest()
        request.utcOffsetMinutes = Self.utcOffsetMinutes

        let response = await client.getJourney(request: request)
        guard let message = response.message else {
            throw Self.transportError(response.error)
        }

        return try message.recentSessions.map { try SessionRecord(proto: $0) }
    }

    public func leaderboard(
        _ board: LeaderboardBoard,
        scope: LeaderboardScope
    ) async throws -> Leaderboard {
        var request = Breathe_V1_GetLeaderboardRequest()
        request.board = board.proto
        request.scope = scope.proto
        request.utcOffsetMinutes = Self.utcOffsetMinutes

        let response = await client.getLeaderboard(request: request)
        guard let message = response.message else {
            throw Self.transportError(response.error)
        }

        return Leaderboard(
            board: board,
            scope: scope,
            entries: message.entries.map {
                LeaderboardEntry(
                    rank: Int($0.rank),
                    displayName: $0.displayName,
                    value: Int($0.value)
                )
            },
            standing: LeaderboardStanding(
                rank: message.caller.hasRank ? Int(message.caller.rank) : nil,
                value: Int(message.caller.value),
                listed: message.caller.listed
            )
        )
    }

    /// Minutes east of UTC, which is the unit every streak the server computes is
    /// expressed in. Read per call rather than stored, so somebody who has flown
    /// gets their new local days on the next request.
    private static var utcOffsetMinutes: Int32 {
        Int32(TimeZone.current.secondsFromGMT() / 60)
    }

    private static func transportError(_ error: (any Error)?) -> JourneyRepositoryError {
        .transport(error?.localizedDescription ?? "the request failed with no message")
    }
}

extension SessionRecord {
    init(proto: Breathe_V1_SessionRecord) throws {
        guard let id = UUID(uuidString: proto.clientSessionID) else {
            throw JourneyRepositoryError.malformedResponse(
                "`\(proto.clientSessionID)` is not a session id"
            )
        }

        self.init(
            id: id,
            techniqueSlug: proto.techniqueSlug,
            startedAt: proto.startedAt.date,
            duration: .milliseconds(proto.durationMs),
            cyclesCompleted: Int(proto.cyclesCompleted),
            breathCount: Int(proto.breathCount),
            completed: proto.completed
        )
    }

    var proto: Breathe_V1_SessionRecord {
        var message = Breathe_V1_SessionRecord()
        message.clientSessionID = id.uuidString
        message.techniqueSlug = techniqueSlug
        let started = timestampParts(startedAt)
        message.startedAt.seconds = started.seconds
        message.startedAt.nanos = started.nanos
        message.durationMs = UInt32(max(0, durationMs))
        message.cyclesCompleted = UInt32(max(0, cyclesCompleted))
        message.breathCount = UInt32(max(0, breathCount))
        message.completed = completed
        return message
    }
}

/// Splits an instant into the two fields `google.protobuf.Timestamp` carries.
///
/// Returned as a pair and assigned through the message's own properties rather
/// than built as a `Google_Protobuf_Timestamp`: SwiftProtobuf is BreatheAPI's
/// dependency and not this target's, so its types can be read through a
/// generated message but never named here. That is the module boundary working
/// rather than an obstacle to it.
///
/// The nanoseconds are clamped, because a rounding that reached a full billion
/// would encode a timestamp the server refuses.
private func timestampParts(_ instant: Date) -> (seconds: Int64, nanos: Int32) {
    let interval = instant.timeIntervalSince1970
    let whole = interval.rounded(.down)

    return (
        seconds: Int64(whole),
        nanos: min(999_999_999, Int32(((interval - whole) * 1_000_000_000).rounded()))
    )
}

extension LeaderboardBoard {
    var proto: Breathe_V1_LeaderboardBoard {
        switch self {
        case .streak: .streak
        case .minutes30d: .minutes30D
        case .bolt: .bolt
        }
    }
}

extension LeaderboardScope {
    var proto: Breathe_V1_LeaderboardScope {
        switch self {
        case .global: .global
        case .ageBand: .ageBand
        }
    }
}
