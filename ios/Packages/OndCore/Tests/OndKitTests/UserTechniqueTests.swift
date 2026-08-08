import Foundation
import OndKit
import Testing

/// The limits the server states, wide enough that a test can put a value
/// clearly inside or clearly outside one.
private let limits = AuthoringLimits(
    phases: [
        PhaseLimit(kind: .inhale, range: .milliseconds(500) ... .milliseconds(10000)),
        PhaseLimit(kind: .exhale, range: .milliseconds(700) ... .milliseconds(12000)),
    ],
    maxNameChars: 60,
    maxStages: 4,
    maxPhasesPerStage: 8,
    cycleRange: 1 ... 99,
    roundRange: 1 ... 10,
    maxTechniques: 2
)

private func draft(name: String = "Mine") -> TechniqueDraft {
    TechniqueDraft(
        name: name,
        goal: .sleep,
        stages: [DraftStage(
            phases: [
                DraftPhase(kind: .inhale, duration: .milliseconds(4000)),
                DraftPhase(kind: .exhale, duration: .milliseconds(8000)),
            ],
            cycles: 10
        )]
    )
}

/// Turns a draft into what the server would return for it: the same `Technique`
/// message the catalogue serves, with the ranges stamped on.
private func stored(_ draft: TechniqueDraft, id: String) -> Technique {
    Technique(
        id: id,
        slug: "own-\(id)",
        name: draft.name,
        summary: "",
        goal: draft.goal,
        stages: draft.stages.map { stage in
            Stage(
                phases: stage.phases.map { phase in
                    Phase(
                        kind: phase.kind,
                        duration: phase.duration,
                        range: limits.range(for: phase.kind) ?? phase.duration ... phase.duration
                    )
                },
                cycles: stage.cycles
            )
        },
        recommendedRounds: draft.rounds,
        origin: .personal
    )
}

/// Stands in for the server, counting calls so a test can tell a patched list
/// from a refetched one.
private actor FakeStore: UserTechniqueStoring {
    private var techniques: [Technique] = []
    private(set) var lists = 0
    var refusal: UserTechniqueRepositoryError?

    init(refusing refusal: UserTechniqueRepositoryError? = nil) {
        self.refusal = refusal
    }

    func listUserTechniques() async throws -> UserTechniqueList {
        lists += 1
        return UserTechniqueList(techniques: techniques, limits: limits)
    }

    func createUserTechnique(_ draft: TechniqueDraft) async throws -> Technique {
        if let refusal {
            throw refusal
        }
        let technique = stored(draft, id: "id-\(techniques.count)")
        techniques.append(technique)
        return technique
    }

    func updateUserTechnique(id: String, to draft: TechniqueDraft) async throws -> Technique {
        if let refusal {
            throw refusal
        }
        return stored(draft, id: id)
    }

    func deleteUserTechnique(id: String) async throws {
        if let refusal {
            throw refusal
        }
        techniques.removeAll { $0.id == id }
    }
}

/// The clause most likely to expose a bad model: an exercise somebody wrote has
/// to play through the same `SessionTimeline` a curated one does. It does
/// because it is the same type — this is what stops that being an accident.
@Suite("Playing an exercise somebody wrote")
struct AuthoredPlaybackTests {
    @Test("An authored exercise lays out the same timeline a curated one would")
    func playsThroughTheSharedTimeline() throws {
        let mine = stored(draft(), id: "id-0")
        let timeline = SessionTimeline(technique: mine)

        // Ten cycles of a four-second inhale and an eight-second exhale.
        #expect(timeline.beats.count == 20)
        #expect(timeline.totalDuration == .milliseconds(120_000))
        #expect(timeline.rounds == 1)

        let opening = try #require(timeline.beat(at: .milliseconds(1000)))
        #expect(opening.kind == .inhale)
        #expect(opening.cycle == 0)

        let later = try #require(timeline.beat(at: .milliseconds(5000)))
        #expect(later.kind == .exhale)
    }

    @Test("A dialled copy of an authored exercise is still theirs")
    func dialledCopiesKeepTheirOrigin() {
        let mine = stored(draft(), id: "id-0")

        #expect(mine.dialled(with: nil).origin == .personal)
    }

    @Test("A curated technique is not mistaken for one somebody wrote")
    func theCatalogueIsTheDefault() {
        let curated = Technique(
            id: "box",
            slug: "box-breathing",
            name: "Box Breathing",
            summary: "",
            goal: .calm,
            stages: [Stage(phases: [Phase(kind: .inhale, duration: .seconds(4))], cycles: 4)],
            recommendedRounds: 1
        )

        #expect(curated.origin == .catalogue)
    }
}

@Suite("Composing within the server's limits")
struct AuthoringLimitsTests {
    @Test("A duration outside its seeded range is brought back inside it")
    func clampsAPhase() {
        var reckless = draft()
        reckless.stages[0].phases[0].duration = .milliseconds(240_000)

        let clamped = limits.clamping(reckless)

        #expect(clamped.stages[0].phases[0].duration == .milliseconds(10000))
    }

    @Test("A kind the server did not seed is left alone rather than guessed at")
    func leavesAnUnseededKindAlone() {
        var held = draft()
        held.stages[0].phases[0] = DraftPhase(kind: .holdOut, duration: .milliseconds(4000))

        let clamped = limits.clamping(held)

        #expect(clamped.stages[0].phases[0].duration == .milliseconds(4000))
        #expect(limits.range(for: .holdOut) == nil)
    }

    @Test("Counts are clamped and over-long lists are cut")
    func clampsTheCounts() {
        var sprawling = draft()
        sprawling.rounds = 99
        sprawling.stages[0].cycles = 0
        sprawling.stages = Array(repeating: sprawling.stages[0], count: 9)

        let clamped = limits.clamping(sprawling)

        #expect(clamped.rounds == 10)
        #expect(clamped.stages.count == 4)
        #expect(clamped.stages[0].cycles == 1)
    }

    @Test("A draft's planned length is what a session of it would take")
    func reportsThePlannedLength() {
        #expect(draft().plannedDuration == .milliseconds(120_000))
    }

    @Test("Editing opens on exactly what is stored")
    func roundTripsAnEdit() {
        let mine = stored(draft(), id: "id-0")
        let editing = TechniqueDraft(editing: mine)

        #expect(editing.name == "Mine")
        #expect(editing.goal == .sleep)
        #expect(editing.stages.count == 1)
        #expect(editing.stages[0].cycles == 10)
        #expect(editing.stages[0].phases.map(\.kind) == [.inhale, .exhale])
        #expect(editing.stages[0].phases.map(\.duration) == [
            .milliseconds(4000),
            .milliseconds(8000),
        ])
    }
}

@Suite("Keeping the list of somebody's own exercises")
@MainActor
struct UserTechniqueModelTests {
    @Test("Nothing is offered before the server has said what the limits are")
    func waitsForTheLimits() async {
        let model = UserTechniqueModel(store: FakeStore())

        #expect(!model.hasRoomForAnother)
        #expect(model.limits == nil)

        await model.loadIfNeeded()

        #expect(model.hasRoomForAnother)
        #expect(model.limits?.maxTechniques == 2)
    }

    @Test("Saving adds to the list without refetching it")
    func patchesRatherThanRefetching() async throws {
        let store = FakeStore()
        let model = UserTechniqueModel(store: store)
        await model.loadIfNeeded()

        let created = try await model.save(draft())

        #expect(model.techniques.map(\.id) == [created.id])
        #expect(await store.lists == 1, "a save is one round trip, not two")
    }

    @Test("Editing replaces the exercise in place rather than adding a copy")
    func replacesInPlace() async throws {
        let model = UserTechniqueModel(store: FakeStore())
        await model.loadIfNeeded()

        let created = try await model.save(draft())
        let edited = try await model.save(draft(name: "Renamed"), replacing: created.id)

        #expect(model.techniques.count == 1)
        #expect(model.techniques[0].id == created.id)
        #expect(edited.name == "Renamed")
    }

    @Test("The ceiling closes the door before the server has to")
    func stopsOfferingAtTheCeiling() async throws {
        let model = UserTechniqueModel(store: FakeStore())
        await model.loadIfNeeded()

        try await model.save(draft())
        #expect(model.hasRoomForAnother)

        try await model.save(draft(name: "Second"))
        #expect(!model.hasRoomForAnother)
    }

    @Test("Deleting stops showing it")
    func removesOnDelete() async throws {
        let model = UserTechniqueModel(store: FakeStore())
        await model.loadIfNeeded()

        let created = try await model.save(draft())
        try await model.delete(created)

        #expect(model.techniques.isEmpty)
    }

    /// A refused save must not take the list down with it — the person is still
    /// editing, and an error screen would take the draft away to say so.
    @Test("A refused save leaves the list alone")
    func aRefusalDoesNotClearTheList() async throws {
        let store = FakeStore()
        let model = UserTechniqueModel(store: store)
        await model.loadIfNeeded()

        let kept = try await model.save(draft())
        await store.refuse(with: .rejected("phase 1 of stage 1 must be between 500ms and 10000ms"))

        await #expect(throws: UserTechniqueRepositoryError.self) {
            try await model.save(draft(name: "Too long"))
        }

        #expect(model.techniques.map(\.id) == [kept.id])
        #expect(model.limits != nil, "the composer still has its limits to render from")
    }
}

private extension FakeStore {
    func refuse(with error: UserTechniqueRepositoryError) {
        refusal = error
    }
}
