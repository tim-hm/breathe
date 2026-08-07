import Foundation
import os

/// Serves the last catalogue the server ever sent when the current one cannot
/// be fetched, or cannot be fetched quickly.
///
/// The offline-first seam for reference data: every successful fetch is written
/// to disk, and a fetch that fails *or misses a deadline* falls back to that
/// copy, so the server being unreachable — or unreachably slow — costs at most
/// freshness. The fallback covers decode failures as well as transport ones —
/// a catalogue this build once represented stays representable, however far the
/// server has moved on. Only a first-ever launch with no connection has nothing
/// to show, and it sees the original error.
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
    private let deadline: Duration

    /// - Parameters:
    ///   - network: the repository that actually fetches — wrapped, not
    ///     replaced, so this type never learns about the wire format.
    ///   - directory: where the snapshots live. Defaults to Application
    ///     Support — data the system backs up and never purges, unlike Caches,
    ///     which would let the OS delete exactly the copy offline needs.
    ///     Tests pass a temporary directory.
    ///   - deadline: how long a fetch may hold the caller once there is a
    ///     catalogue on disk. Deliberately far shorter than the connection
    ///     timeout: a captive portal or a stalled cellular handover keeps a
    ///     socket open for tens of seconds, and the app's first screen is not
    ///     entitled to any of them while a good catalogue sits beside it. Long
    ///     enough that a healthy round trip still wins, so what somebody sees is
    ///     normally today's catalogue rather than yesterday's.
    public init(
        caching network: any TechniqueReading,
        directory: URL = .applicationSupportDirectory,
        deadline: Duration = .milliseconds(1500)
    ) {
        self.network = network
        techniquesURL = directory.appending(path: "catalogue.json")
        foundationsURL = directory.appending(path: "foundations.json")
        self.deadline = deadline
    }

    public func listTechniques() async throws -> [Technique] {
        try await fetch(from: { try await network.listTechniques() }, fallback: techniquesURL)
    }

    public func listFoundations() async throws -> [FoundationTopic] {
        try await fetch(from: { try await network.listFoundations() }, fallback: foundationsURL)
    }

    /// The snapshot is read before the fetch is awaited, not after it fails.
    ///
    /// The other way round makes the network a gate in front of the offline
    /// copy: airplane mode happens to work because it fails fast, while a
    /// captive portal holds the first screen on a spinner for the whole
    /// connection timeout with a perfectly good catalogue on disk.
    ///
    /// The cost is that a link *consistently* slower than the deadline loses
    /// every race, and its snapshot then never advances — freshness traded for a
    /// first screen, which is the trade this whole type exists to make. Letting
    /// the loser finish and write anyway would need it to outlive the group, and
    /// a group does not return until its children have.
    private func fetch<Value: Codable & Sendable>(
        from network: @escaping @Sendable () async throws -> Value,
        fallback url: URL
    ) async throws -> Value {
        guard let cached: Value = restore(from: url) else {
            // A first-ever launch has nothing to fall back to, so the fetch gets
            // as long as the connection takes and its failure is the caller's.
            let fresh = try await network()
            persist(fresh, at: url)
            return fresh
        }

        return await withTaskGroup(of: Value.self) { group in
            group.addTask {
                // A fetch that fails outright is the offline case, and the
                // snapshot is already the answer — no reason to sit out the
                // rest of the deadline for it.
                guard let fresh = try? await network() else { return cached }
                persist(fresh, at: url)
                return fresh
            }
            group.addTask { [deadline] in
                try? await Task.sleep(for: deadline)
                return cached
            }

            // Connect cancels the underlying request rather than merely
            // abandoning it, which is what lets this return at the deadline
            // instead of waiting the loser out. `next()` is non-nil while the
            // group has children; the coalesce is what keeps that a fact the
            // compiler checks rather than a force unwrap.
            let first = await group.next() ?? cached
            group.cancelAll()
            return first
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
