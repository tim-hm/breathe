@testable import BreatheKit
import Foundation
import Testing

/// Drives the real `TechniqueListModel` state machine through the
/// `TechniqueReading` seam — the protocol exists so this suite needs no server.
@MainActor
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
            phases: [Phase(kind: .inhale, duration: .milliseconds(4000))],
            recommendedCycles: 8
        )
    }

    @Test("A successful load lands in .loaded with order preserved")
    func loadsTechniques() async {
        let model = TechniqueListModel(
            techniques: StubReader(result: .success([technique(slug: "a"), technique(slug: "b")]))
        )

        await model.load()

        guard case let .loaded(techniques) = model.state else {
            Issue.record("expected .loaded, got \(model.state)")
            return
        }
        #expect(techniques.map(\Technique.slug) == ["a", "b"])
    }

    /// The failure has to stay distinguishable from an empty catalogue — a list
    /// view that renders "no techniques" when the server is unreachable is the
    /// bug this guards.
    @Test("A transport failure lands in .failed, not an empty .loaded")
    func propagatesTransportFailure() async {
        let model = TechniqueListModel(
            techniques: StubReader(result: .failure(.transport("offline")))
        )

        await model.load()

        guard case .failed = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
    }
}
