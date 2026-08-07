import Foundation
import OndAPI

public enum JourneyRepositoryError: LocalizedError, Equatable {
    /// The RPC itself failed — no network, server down, non-OK gRPC status.
    /// Everything the journey does over the network is optional, so a caller's
    /// correct response is almost always to try again later.
    case transport(String)
    /// The server understood the request and refused it on a condition somebody
    /// can put right. Today that is only `AgeBandUnset`: the decade board asked
    /// for by a profile that has not said which decade. Its own case because
    /// folding it into `.transport` presents the one actionable leaderboard
    /// failure as an outage, to a person with full signal.
    case failedPrecondition(String)
    /// The response parsed but described something this app cannot represent.
    /// Distinct from `.transport` because retrying will not help: the client and
    /// server contracts have diverged.
    case malformedResponse(String)
    /// A value on this device does not fit the field the wire carries it in.
    ///
    /// These numbers come back from `sessions.json` and `bolt-scores.json`,
    /// plain files a person may edit and a backup may restore, and every counter
    /// the proto carries is unsigned 32-bit. Thrown rather than trapped because
    /// `SessionSyncQueue.sync()` runs on every foreground: a trap there is a
    /// crash loop with no way out short of deleting the app.
    ///
    /// What it costs is a sync that stops rather than an app that crashes — the
    /// offending record sits at the head of the queue and everything later waits
    /// behind it. Range-checking where the file is decoded, on `SessionRecord`
    /// itself, would cost one record instead of all of them; this case is as
    /// deep as the wire boundary can put it.
    case malformedRequest(String)

    /// Carries the associated message. Without this conformance
    /// `localizedDescription` bridges to a bare `NSError`, and every log line
    /// and failure banner reading it says "The operation couldn't be completed".
    public var errorDescription: String? {
        switch self {
        case let .transport(message): "the request failed: \(message)"
        case let .failedPrecondition(message): "the request was refused: \(message)"
        case let .malformedResponse(message): "the response could not be read: \(message)"
        case let .malformedRequest(message): "the request could not be built: \(message)"
        }
    }
}

/// One page of the history the server holds, and where the next one starts.
///
/// A page rather than a list because the restore path asks for the whole
/// archive, not the screen's strip: somebody with years of practice has more
/// sessions than one response should carry, and a single bounded call would hand
/// back the most recent few and call the restore done.
public struct StoredSessionPage: Sendable {
    public let sessions: [SessionRecord]

    /// Pass back to `storedSessions(after:)` for the page behind this one. `nil`
    /// means this page reached the end of the history, which is the only signal
    /// a restore has that it has recovered everything.
    public let nextPageToken: String?

    public init(sessions: [SessionRecord], nextPageToken: String? = nil) {
        self.sessions = sessions
        self.nextPageToken = nextPageToken
    }
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
    func record(_ sessions: [SessionRecord]) async throws

    /// Tells the server to forget sessions deleted on this device. Idempotent
    /// on each id, and an id the server never held is not an error — a caller
    /// holding a tombstone is entitled to ask again until it is sure.
    func delete(_ ids: [SessionRecord.ID]) async throws

    /// Sends one controlled-pause score.
    func record(_ score: BoltScore) async throws

    /// One page of the sessions the server holds — the restore path after a
    /// reinstall, where the Keychain identity outlived the local file.
    ///
    /// - Parameter pageToken: `nil` for the newest page, otherwise the
    ///   `nextPageToken` of the page before it. The value is the server's to
    ///   mint and this app's only to carry.
    func storedSessions(after pageToken: String?) async throws -> StoredSessionPage

    func leaderboard(_ board: LeaderboardBoard, scope: LeaderboardScope) async throws -> Leaderboard
}

/// The only type that touches the generated journey types, mirroring
/// `TechniqueRepository` and `ProfileRepository`.
public struct JourneyRepository: JourneySyncing {
    private let client: Breathe_V1_JourneyServiceClient

    public init(baseURL: URL, identity: any UserIdentityStore) {
        client = OndClients.journeyService(baseURL: baseURL, userId: identity.userId)
    }

    public func record(_ sessions: [SessionRecord]) async throws {
        var request = Breathe_V1_RecordSessionsRequest()
        // One unrepresentable session fails the batch rather than being dropped
        // from it, matching what the server does with a batch it cannot accept:
        // a send silently short of what the caller handed over is worse than a
        // deferred one. See `malformedRequest` for what that costs.
        request.sessions = try sessions.map { try $0.proto }

        let response = await client.recordSessions(request: request)
        guard response.message != nil else {
            throw Self.failure(
                unmetPrecondition: response.code == .failedPrecondition,
                response.error
            )
        }
    }

    public func delete(_ ids: [SessionRecord.ID]) async throws {
        var request = Breathe_V1_DeleteSessionsRequest()
        request.clientSessionIds = ids.map(\.uuidString)

        let response = await client.deleteSessions(request: request)
        guard response.message != nil else {
            throw Self.failure(
                unmetPrecondition: response.code == .failedPrecondition,
                response.error
            )
        }
    }

    public func record(_ score: BoltScore) async throws {
        var request = Breathe_V1_RecordBoltScoreRequest()
        request.clientScoreID = score.id.uuidString
        request.seconds = try onTheWire(score.seconds, "a pause in seconds", of: score.id)
        let measured = try timestampParts(score.measuredAt)
        request.measuredAt.seconds = measured.seconds
        request.measuredAt.nanos = measured.nanos

        let response = await client.recordBoltScore(request: request)
        guard response.message != nil else {
            throw Self.failure(
                unmetPrecondition: response.code == .failedPrecondition,
                response.error
            )
        }
    }

    public func storedSessions(after pageToken: String?) async throws -> StoredSessionPage {
        var request = Breathe_V1_GetJourneyRequest()
        request.utcOffsetMinutes = Self.utcOffsetMinutes
        request.limit = Self.restorePageSize
        if let pageToken {
            request.pageToken = pageToken
        }

        let response = await client.getJourney(request: request)
        guard let message = response.message else {
            throw Self.failure(
                unmetPrecondition: response.code == .failedPrecondition,
                response.error
            )
        }

        return try StoredSessionPage(
            sessions: message.recentSessions.map { try SessionRecord(proto: $0) },
            nextPageToken: message.hasNextPageToken ? message.nextPageToken : nil
        )
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
            throw Self.failure(
                unmetPrecondition: response.code == .failedPrecondition,
                response.error
            )
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

    /// How much history one restore page asks for.
    ///
    /// The server's own ceiling, so a restore costs the fewest round trips it
    /// can. Larger than anything a screen would ask for on purpose: the journey
    /// tab's strip is drawn from the local store, and this call exists only for
    /// the device that has no local store yet.
    private static let restorePageSize: UInt32 = 500

    /// Minutes east of UTC, which is the unit every streak the server computes is
    /// expressed in. Read per call rather than stored, so somebody who has flown
    /// gets their new local days on the next request.
    private static var utcOffsetMinutes: Int32 {
        Int32(TimeZone.current.secondsFromGMT() / 60)
    }

    /// The one distinction a caller acts on: whether anything but waiting could
    /// change the answer.
    ///
    /// The status arrives as a flag rather than as a `Code` because Connect is
    /// OndAPI's dependency and not this target's — the same boundary
    /// `timestampParts` keeps with SwiftProtobuf. Every call tests it, not only
    /// the leaderboard's, so a server that begins refusing one of the others on
    /// a condition does not arrive mislabelled as an outage.
    private static func failure(
        unmetPrecondition: Bool,
        _ error: (any Error)?
    ) -> JourneyRepositoryError {
        let message = error?.localizedDescription ?? "the server sent no message"
        return unmetPrecondition ? .failedPrecondition(message) : .transport(message)
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

    /// Throwing, unlike the decoders it sits beside, because every number here
    /// arrives from `sessions.json` — a file `SessionRecord`'s own doc promises
    /// a person can read, which a backup can restore and `JSONFileStore.load()`
    /// range-checks not at all — and lands in an unsigned 32-bit field.
    var proto: Breathe_V1_SessionRecord {
        get throws {
            var message = Breathe_V1_SessionRecord()
            message.clientSessionID = id.uuidString
            message.techniqueSlug = techniqueSlug
            let started = try timestampParts(startedAt)
            message.startedAt.seconds = started.seconds
            message.startedAt.nanos = started.nanos
            message.durationMs = try onTheWire(durationMs, "a duration in ms", of: id)
            message.cyclesCompleted = try onTheWire(cyclesCompleted, "a cycle count", of: id)
            message.breathCount = try onTheWire(breathCount, "a breath count", of: id)
            message.completed = completed
            return message
        }
    }
}

/// Splits an instant into the two fields `google.protobuf.Timestamp` carries.
///
/// Returned as a pair and assigned through the message's own properties rather
/// than built as a `Google_Protobuf_Timestamp`: SwiftProtobuf is OndAPI's
/// dependency and not this target's, so its types can be read through a
/// generated message but never named here. That is the module boundary working
/// rather than an obstacle to it.
///
/// The nanoseconds are clamped, because a rounding that reached a full billion
/// would encode a timestamp the server refuses. Past the seconds guard the
/// fraction is known to be in `0 ..< 1`, so they cannot overflow.
private func timestampParts(_ instant: Date) throws -> (seconds: Int64, nanos: Int32) {
    let interval = instant.timeIntervalSince1970
    let whole = interval.rounded(.down)

    guard let seconds = Int64(exactly: whole) else {
        throw JourneyRepositoryError.malformedRequest(
            "\(instant) is not an instant the wire can carry"
        )
    }

    return (
        seconds: seconds,
        nanos: min(999_999_999, Int32(((interval - whole) * 1_000_000_000).rounded()))
    )
}

/// One of the wire's unsigned 32-bit counters.
///
/// Refused rather than clamped: a clamp on either end reports a session nobody
/// did, and a person's own figures are the ones they are most likely to believe.
///
/// - Parameters:
///   - value: the count as this device stores it, in `Int`.
///   - name: what it counts, for the log a skipped sync leaves behind.
///   - owner: the record it belongs to, so the log names something findable in
///     the file.
private func onTheWire(_ value: Int, _ name: String, of owner: UUID) throws -> UInt32 {
    guard let converted = UInt32(exactly: value) else {
        throw JourneyRepositoryError.malformedRequest(
            "\(owner) holds \(name) of \(value), which the wire cannot carry"
        )
    }
    return converted
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
