import Foundation

/// One BOLT-style controlled-pause measurement.
///
/// Seconds rather than milliseconds, and that is not laziness: the test ends
/// when a person feels the first definite urge to breathe, and precision past a
/// second would claim an accuracy the measurement does not have.
///
/// Recorded locally first, exactly like a session, and carrying the id the sync
/// uses as its idempotency key.
public struct BoltScore: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let seconds: Int
    public let measuredAt: Date

    public init(id: UUID = UUID(), seconds: Int, measuredAt: Date = .now) {
        self.id = id
        self.seconds = seconds
        self.measuredAt = measuredAt
    }
}

/// Somewhere to keep controlled-pause scores, on the device that measured them.
///
/// Non-throwing for the same reason `SessionRecording` is: a failed local write
/// is nothing the person who just held their breath can act on. Implementations
/// log and carry on.
public protocol BoltScoreRecording: Sendable {
    func record(_ score: BoltScore) async
    /// Every recorded score, oldest first.
    func recordedScores() async -> [BoltScore]
}

public extension BoltScoreRecording {
    /// The best score this device knows about, or `nil` before the first test.
    ///
    /// Computed locally rather than read back from the server, so the BOLT card
    /// is right in airplane mode. The server answers the same question for the
    /// leaderboard, where it has everybody's history and this device does not.
    func personalBest() async -> Int? {
        await recordedScores().map(\.seconds).max()
    }
}

/// Score history as one JSON file, beside the sessions.
public actor FileBoltScoreStore: BoltScoreRecording, PersonalStore {
    private let file: JSONFileStore<BoltScore>

    /// - Parameter directory: where `bolt-scores.json` lives. Application
    ///   Support by default, for the same reason sessions live there.
    public init(directory: URL = .applicationSupportDirectory) {
        file = JSONFileStore(
            directory: directory,
            fileName: "bolt-scores.json",
            category: "bolt-store"
        )
    }

    public func record(_ score: BoltScore) async {
        var scores = file.load()
        scores.append(score)
        file.save(scores)
    }

    public func recordedScores() async -> [BoltScore] {
        file.load()
    }

    /// Erasing this is what blanks the number on the wrist, since the phone
    /// mirrors its best pause to the watch and can only mirror what it has.
    public func erase() async {
        file.erase()
    }
}
