import Foundation
import os

/// Serves the last catalogue the server ever sent when the current one cannot
/// be fetched.
///
/// The offline-first seam for reference data: every successful fetch is written
/// to disk, and any failed one falls back to that copy, so the server being
/// unreachable costs at most freshness. The fallback covers decode failures as
/// well as transport ones — a catalogue this build once represented stays
/// representable, however far the server has moved on. Only a first-ever
/// launch with no connection has nothing to show, and it sees the original
/// error.
///
/// A struct, not an actor: each write atomically replaces a whole file, and
/// concurrent loads can only race to write equivalent snapshots — last one
/// wins, nothing interleaves.
public struct CachedTechniqueRepository: TechniqueReading {
    /// The running app's subsystem, not a hard-coded bundle id: this module is
    /// shared, and M9's watch app is a second bundle that should log as itself.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BreatheKit",
        category: "catalogue-cache"
    )

    private let network: any TechniqueReading
    private let techniquesURL: URL
    private let foundationsURL: URL

    /// - Parameters:
    ///   - network: the repository that actually fetches — wrapped, not
    ///     replaced, so this type never learns about the wire format.
    ///   - directory: where the snapshots live. Defaults to Application
    ///     Support — data the system backs up and never purges, unlike Caches,
    ///     which would let the OS delete exactly the copy offline needs.
    ///     Tests pass a temporary directory.
    public init(
        caching network: any TechniqueReading,
        directory: URL = .applicationSupportDirectory
    ) {
        self.network = network
        techniquesURL = directory.appending(path: "catalogue.json")
        foundationsURL = directory.appending(path: "foundations.json")
    }

    public func listTechniques() async throws -> [Technique] {
        try await fetch(from: network.listTechniques, fallback: techniquesURL)
    }

    public func listFoundations() async throws -> [FoundationTopic] {
        try await fetch(from: network.listFoundations, fallback: foundationsURL)
    }

    private func fetch<Value: Codable>(
        from network: () async throws -> Value,
        fallback url: URL
    ) async throws -> Value {
        do {
            let fresh = try await network()
            persist(fresh, at: url)
            return fresh
        } catch {
            guard let cached: Value = restore(from: url) else {
                throw error
            }
            return cached
        }
    }

    /// Failure is logged and swallowed: the fresh catalogue in hand is what the
    /// caller came for, and an unwritable cache is tomorrow's problem, not a
    /// reason to fail today's fetch.
    private func persist(_ value: some Encodable, at url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic, so a crash mid-write leaves the previous snapshot rather
            // than a truncated file that reads back as no catalogue at all.
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            Self.logger.error("failed to cache the catalogue: \(error.localizedDescription)")
        }
    }

    private func restore<Value: Decodable>(from url: URL) -> Value? {
        // No file is the normal state until the first successful fetch, so it
        // is checked rather than caught — an expected condition should not log
        // as an error.
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            Self.logger.error("failed to read the cached catalogue: \(error.localizedDescription)")
            return nil
        }
    }
}
