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

        func listFoundations() async throws -> [FoundationTopic] {
            []
        }
    }

    private actor Counter {
        private(set) var count = 0

        func bump() {
            count += 1
        }
    }

    private struct CountingReader: TechniqueReading {
        let counter: Counter
        let techniques: [Technique]

        func listTechniques() async throws -> [Technique] {
            await counter.bump()
            return techniques
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
                Stage(phases: [Phase(kind: .inhale, duration: .milliseconds(4000))], cycles: 8),
            ],
            recommendedRounds: 1
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

    /// The model is shared by every tab root, and each of them joins the load
    /// on appearance. One fetch must serve them all — the bug this guards is a
    /// tab switch tearing a loaded catalogue back down to a spinner.
    @Test("Every loadIfNeeded joins one shared fetch")
    func sharesOneLoad() async {
        let counter = Counter()
        let model = TechniqueListModel(
            techniques: CountingReader(counter: counter, techniques: [technique(slug: "a")])
        )

        async let first: Void = model.loadIfNeeded()
        async let second: Void = model.loadIfNeeded()
        _ = await (first, second)
        await model.loadIfNeeded()

        #expect(await counter.count == 1)
        guard case .loaded = model.state else {
            Issue.record("expected .loaded, got \(model.state)")
            return
        }
    }

    @Test("An explicit load still refetches after the shared one")
    func explicitLoadRefetches() async {
        let counter = Counter()
        let model = TechniqueListModel(
            techniques: CountingReader(counter: counter, techniques: [technique(slug: "a")])
        )

        await model.loadIfNeeded()
        await model.load()

        #expect(await counter.count == 2)
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
