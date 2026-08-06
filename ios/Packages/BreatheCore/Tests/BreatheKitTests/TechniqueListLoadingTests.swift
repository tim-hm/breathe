@testable import BreatheKit
import Foundation
import Testing

/// Redeems the `TechniqueReading` protocol: it exists so the loading path can be
/// exercised without a server, and these are the substitutions that do it.
@Suite("Loading the technique catalogue")
struct TechniqueListLoadingTests {
    private struct StubReader: TechniqueReading {
        let result: Result<[Technique], TechniqueRepositoryError>

        func listTechniques() async throws -> [Technique] {
            try result.get()
        }
    }

    private func technique(slug: String) -> Technique {
        Technique(
            id: slug,
            slug: slug,
            name: slug,
            summary: "",
            goal: .calm,
            phases: [Phase(kind: .inhale, duration: .milliseconds(4000))]
        )
    }

    @Test("A successful load surfaces the techniques in order")
    func loadsTechniques() async throws {
        let reader = StubReader(result: .success([technique(slug: "a"), technique(slug: "b")]))

        let loaded = try await reader.listTechniques()

        #expect(loaded.map(\Technique.slug) == ["a", "b"])
    }

    /// The failure has to stay distinguishable from an empty catalogue — a list
    /// view that renders "no techniques" when the server is unreachable is the
    /// bug this guards.
    @Test("A transport failure propagates rather than yielding an empty list")
    func propagatesTransportFailure() async {
        let reader = StubReader(result: .failure(.transport("offline")))

        await #expect(throws: TechniqueRepositoryError.self) {
            try await reader.listTechniques()
        }
    }
}
