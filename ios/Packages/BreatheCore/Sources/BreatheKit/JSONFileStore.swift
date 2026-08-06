import Foundation
import os

/// A JSON array of `Element`, held in one file.
///
/// Deliberately not an actor. Every caller is already one, and an actor here
/// would put a second hop between a session ending and the write that records
/// it, for serialisation the owner is providing anyway.
///
/// Rewriting the whole file per append is the deliberate trade: a person records
/// single-digit sessions a day, the file stays kilobytes for years, and an
/// append-only format would need its own reader before the sync queue could
/// batch what it finds. Revisit when there is enough history for that to be
/// false.
struct JSONFileStore<Element: Codable & Sendable>: Sendable {
    private let fileURL: URL
    private let logger: Logger

    init(directory: URL, fileName: String, category: String) {
        fileURL = directory.appending(path: fileName)
        // The running app's subsystem, not a hard-coded bundle id: this module
        // is shared, and M9's watch app is a second bundle that should log as
        // itself.
        logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "BreatheKit",
            category: category
        )
    }

    /// Everything on disk, oldest first. An unreadable file reads as empty.
    func load() -> [Element] {
        // No file is the normal state until the first write, so it is checked
        // rather than caught — an expected condition should not spend every
        // launch before the first session logging an error.
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Element].self, from: Data(contentsOf: fileURL))
        } catch {
            // Unreadable history is not worth failing a session over, and it is
            // not worth deleting either: leaving the file alone keeps whatever
            // it holds available to a later version that can read it.
            logger
                .error("failed to read \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return []
        }
    }

    func save(_ elements: [Element]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic, so a crash mid-write leaves the previous contents rather
            // than a truncated file that reads back as no history at all.
            try encoder.encode(elements).write(to: fileURL, options: .atomic)
        } catch {
            logger
                .error(
                    "failed to write \(fileURL.lastPathComponent): \(error.localizedDescription)"
                )
        }
    }
}
