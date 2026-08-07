import Foundation
@testable import OndKit
import Testing

/// What is under test is the offline promise for reference data: once any fetch
/// has succeeded, the server being unreachable costs freshness, never the
/// catalogue.
@Suite("Cached technique repository")
struct CachedTechniqueRepositoryTests {
    /// Answers with whatever it was configured with, and can be told to refuse
    /// — which is what a stopped API service looks like.
    private final class ScriptedReader: TechniqueReading, @unchecked Sendable {
        var techniques: [Technique]
        var foundations: [FoundationTopic]
        var isReachable = true

        init(techniques: [Technique] = [], foundations: [FoundationTopic] = []) {
            self.techniques = techniques
            self.foundations = foundations
        }

        func listTechniques() async throws -> [Technique] {
            guard isReachable else {
                throw TechniqueRepositoryError.transport("connection refused")
            }
            return techniques
        }

        func listFoundations() async throws -> [FoundationTopic] {
            guard isReachable else {
                throw TechniqueRepositoryError.transport("connection refused")
            }
            return foundations
        }
    }

    /// A directory nobody else shares, torn down by the OS rather than by a
    /// cleanup step a failing test would skip.
    private func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "catalogue-cache-tests.\(UUID().uuidString)")
    }

    private func technique(slug: String) -> Technique {
        Technique(
            id: slug,
            slug: slug,
            name: slug,
            summary: "",
            goal: .calm,
            stages: [Stage(
                phases: [
                    Phase(kind: .inhale, duration: .seconds(4)),
                    Phase(kind: .exhale, duration: .seconds(4), range: .seconds(2) ... .seconds(8)),
                ],
                cycles: 4
            )],
            recommendedRounds: 1,
            safetyNote: "seated only"
        )
    }

    @Test("A fetched catalogue survives the server becoming unreachable")
    func fallsBackToTheLastFetch() async throws {
        let directory = temporaryDirectory()
        let reader = ScriptedReader(
            techniques: [technique(slug: "box-breathing")],
            foundations: [FoundationTopic(slug: "why", question: "Why?", answer: "Because.")]
        )
        let repository = CachedTechniqueRepository(caching: reader, directory: directory)

        _ = try await repository.listTechniques()
        _ = try await repository.listFoundations()
        reader.isReachable = false

        // A second repository over the same directory, because the fallback
        // that matters is a later launch reading a file an earlier one wrote —
        // not one instance remembering its own state.
        let relaunched = CachedTechniqueRepository(caching: reader, directory: directory)
        let techniques = try await relaunched.listTechniques()
        let foundations = try await relaunched.listFoundations()

        #expect(techniques == [technique(slug: "box-breathing")])
        #expect(foundations.map(\.slug) == ["why"])
    }

    @Test("A first-ever launch with no connection sees the original error")
    func rethrowsWithNothingCached() async {
        let reader = ScriptedReader()
        reader.isReachable = false
        let repository = CachedTechniqueRepository(caching: reader, directory: temporaryDirectory())

        await #expect(throws: TechniqueRepositoryError.transport("connection refused")) {
            _ = try await repository.listTechniques()
        }
    }

    @Test("A newer fetch replaces the snapshot an older one wrote")
    func keepsTheLatestFetch() async throws {
        let directory = temporaryDirectory()
        let reader = ScriptedReader(techniques: [technique(slug: "old")])
        let repository = CachedTechniqueRepository(caching: reader, directory: directory)

        _ = try await repository.listTechniques()
        reader.techniques = [technique(slug: "new")]
        _ = try await repository.listTechniques()
        reader.isReachable = false

        let techniques = try await repository.listTechniques()
        #expect(techniques.map(\.slug) == ["new"])
    }

    @Test("An unreadable snapshot falls through to the fetch error")
    func survivesACorruptCacheFile() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "catalogue.json"))

        let reader = ScriptedReader()
        reader.isReachable = false
        let repository = CachedTechniqueRepository(caching: reader, directory: directory)

        await #expect(throws: TechniqueRepositoryError.transport("connection refused")) {
            _ = try await repository.listTechniques()
        }
    }
}
