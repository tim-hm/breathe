import Foundation
import os

/// Session history as one JSON file.
///
/// An actor because the write is read-modify-write and a session ending while a
/// future sync is draining the file must not interleave.
///
/// Rewriting the whole file per session is the deliberate trade: a person
/// records single-digit sessions a day, the file stays kilobytes for years, and
/// an append-only format would need its own reader before M5's sync could batch
/// what it finds. Revisit when there is enough history for that to be false.
public actor FileSessionStore: SessionRecording {
    /// The running app's subsystem, not a hard-coded bundle id: this module is
    /// shared, and M9's watch app is a second bundle that should log as itself.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BreatheKit",
        category: "session-store"
    )

    private let fileURL: URL

    /// - Parameter directory: where `sessions.json` lives. Defaults to
    ///   Application Support — user data the system backs up and never purges,
    ///   unlike Caches. Tests pass a temporary directory.
    public init(directory: URL = .applicationSupportDirectory) {
        fileURL = directory.appending(path: "sessions.json")
    }

    public func record(_ session: SessionRecord) async {
        var sessions = await recordedSessions()
        sessions.append(session)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic, so a crash mid-write leaves the previous history rather
            // than a truncated file that reads back as no history at all.
            try encoder.encode(sessions).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("failed to record session: \(error.localizedDescription)")
        }
    }

    public func recordedSessions() async -> [SessionRecord] {
        // No file is the normal state until the first session ends, so it is
        // checked rather than caught — an expected condition should not spend
        // every launch before the first session logging an error.
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([SessionRecord].self, from: Data(contentsOf: fileURL))
        } catch {
            // Unreadable history is not worth failing a session over, and it is
            // not worth deleting either: leaving the file alone keeps whatever
            // it holds available to a later version that can read it.
            Self.logger.error("failed to read session history: \(error.localizedDescription)")
            return []
        }
    }
}
