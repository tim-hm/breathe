@testable import BreatheKit
import Foundation
import Testing

/// The offline-first rule for the catalogue, in the case that hides it.
///
/// Airplane mode is not the interesting failure: the socket is refused at once,
/// so a network-first fetch happens to fall through to the cache quickly enough
/// that nothing looks wrong. A captive portal, a stalled cellular handover, or a
/// slow server holds the connection instead — and the app's first screen is what
/// waits.
///
/// The other direction — a fetch that answers in time replacing the snapshot —
/// is already pinned by `CachedTechniqueRepositoryTests.keepsTheLatestFetch`,
/// which only reads back the newer catalogue if the live fetch won its race.
@Suite("Reaching the catalogue past a stalled connection")
struct CatalogueDeadlineTests {
    /// Never answers, which is what a held-open connection looks like from here.
    private struct StalledReader: TechniqueReading {
        func listTechniques() async throws -> [Technique] {
            try await Task.sleep(for: .seconds(60))
            return []
        }

        func listFoundations() async throws -> [FoundationTopic] {
            try await Task.sleep(for: .seconds(60))
            return []
        }
    }

    private struct AnsweringReader: TechniqueReading {
        let techniques: [Technique]

        func listTechniques() async throws -> [Technique] {
            techniques
        }

        func listFoundations() async throws -> [FoundationTopic] {
            []
        }
    }

    private func technique(slug: String) -> Technique {
        Technique(
            id: slug,
            slug: slug,
            name: slug,
            summary: "",
            goal: .calm,
            stages: [
                Stage(phases: [Phase(kind: .inhale, duration: .seconds(4))], cycles: 4),
            ],
            recommendedRounds: 1
        )
    }

    private func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "catalogue-deadline-tests.\(UUID().uuidString)")
    }

    @Test("A stalled fetch gives way to the snapshot instead of holding the screen")
    func aStalledFetchYieldsToTheCache() async throws {
        let directory = temporaryDirectory()
        let seeded = CachedTechniqueRepository(
            caching: AnsweringReader(techniques: [technique(slug: "box-breathing")]),
            directory: directory
        )
        _ = try await seeded.listTechniques()

        let stalled = CachedTechniqueRepository(
            caching: StalledReader(),
            directory: directory,
            deadline: .milliseconds(20)
        )

        #expect(try await stalled.listTechniques().map(\.slug) == ["box-breathing"])
    }
}
