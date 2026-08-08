import Foundation

/// One phase somebody is composing.
///
/// `Identifiable` on a minted id rather than on its position, because a composer
/// reorders and deletes: a `ForEach` keyed on an index moves the wrong row's
/// focus the moment anything before it changes. The id is never sent — the
/// server numbers phases by their position in the draft it receives.
public struct DraftPhase: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var kind: PhaseKind
    public var duration: Duration

    public init(id: UUID = UUID(), kind: PhaseKind, duration: Duration) {
        self.id = id
        self.kind = kind
        self.duration = duration
    }
}

/// One stage somebody is composing. No `openEnded`: a hold the person ends
/// belongs to the curated protocols that carry the copy explaining it, and the
/// contract has no way to author one.
public struct DraftStage: Sendable, Equatable {
    public var phases: [DraftPhase]
    public var cycles: Int

    public init(phases: [DraftPhase], cycles: Int) {
        self.phases = phases
        self.cycles = cycles
    }
}

/// A technique somebody is building, before the server has accepted it.
///
/// Mutable where `Technique` is not, because this is what a composer's bindings
/// write into. It converts to a `Technique` only by being stored: what comes
/// back carries the id, the slug, and the safe ranges, none of which the person
/// composing owns.
public struct TechniqueDraft: Sendable, Equatable {
    public var name: String
    public var goal: TechniqueGoal
    public var stages: [DraftStage]
    /// How many times the whole stage list repeats. One while the composer
    /// authors a single stage, where a round and a cycle would be the same
    /// number said twice.
    public var rounds: Int

    public init(name: String, goal: TechniqueGoal, stages: [DraftStage], rounds: Int = 1) {
        self.name = name
        self.goal = goal
        self.stages = stages
        self.rounds = rounds
    }

    /// How long a session of this draft would take, for the composer to show
    /// while somebody is still deciding.
    public var plannedDuration: Duration {
        let perRound = stages.reduce(Duration.zero) { total, stage in
            total + stage.phases.reduce(.zero) { $0 + $1.duration } * max(stage.cycles, 1)
        }
        return perRound * max(rounds, 1)
    }
}

public extension TechniqueDraft {
    /// The draft that edits `technique`.
    ///
    /// Round-trips a stored exercise back into the shape the composer works in,
    /// so Edit opens on exactly what is being played rather than on a
    /// reconstruction of it.
    init(editing technique: Technique) {
        self.init(
            name: technique.name,
            goal: technique.goal,
            stages: technique.stages.map { stage in
                DraftStage(
                    phases: stage.phases.map { DraftPhase(kind: $0.kind, duration: $0.duration) },
                    cycles: stage.cycles
                )
            },
            rounds: technique.recommendedRounds
        )
    }
}

/// One phase kind, and how long a phase of it may be.
public struct PhaseLimit: Sendable, Equatable {
    public let kind: PhaseKind
    public let range: ClosedRange<Duration>

    public init(kind: PhaseKind, range: ClosedRange<Duration>) {
        self.kind = kind
        self.range = range
    }
}

/// What a composer is allowed to build, as the server states it.
///
/// Fetched rather than declared. The per-phase ranges are the catalogue's own
/// seeded evidence and the counts are the server's ceilings, so a client that
/// hardcoded either would be offering something the server may refuse — which is
/// a dial somebody drags to a number that then will not save.
public struct AuthoringLimits: Sendable, Equatable {
    /// In the order a cycle runs — inhale, hold, exhale, hold — which is the
    /// order a picker offers them in. A kind absent from this list cannot be
    /// authored at all.
    public let phases: [PhaseLimit]
    public let maxNameChars: Int
    public let maxStages: Int
    public let maxPhasesPerStage: Int
    public let cycleRange: ClosedRange<Int>
    public let roundRange: ClosedRange<Int>
    public let maxTechniques: Int

    public init(
        phases: [PhaseLimit],
        maxNameChars: Int,
        maxStages: Int,
        maxPhasesPerStage: Int,
        cycleRange: ClosedRange<Int>,
        roundRange: ClosedRange<Int>,
        maxTechniques: Int
    ) {
        self.phases = phases
        self.maxNameChars = maxNameChars
        self.maxStages = maxStages
        self.maxPhasesPerStage = maxPhasesPerStage
        self.cycleRange = cycleRange
        self.roundRange = roundRange
        self.maxTechniques = maxTechniques
    }

    /// How long a phase of `kind` may be, or nil for a kind with no seeded
    /// evidence behind any duration.
    public func range(for kind: PhaseKind) -> ClosedRange<Duration>? {
        phases.first { $0.kind == kind }?.range
    }

    /// `draft` with every value brought inside these limits.
    ///
    /// The composer's own guard, and deliberately a clamp rather than a
    /// refusal: a dial cannot be dragged past its range, so the only way to
    /// arrive outside one is to have opened an exercise the seed has since
    /// narrowed under. The server checks the same values again — this is what
    /// stops somebody being told no, not what decides it.
    public func clamping(_ draft: TechniqueDraft) -> TechniqueDraft {
        var clamped = draft
        clamped.rounds = roundRange.clamping(draft.rounds)
        clamped.stages = draft.stages.prefix(maxStages).map { stage in
            var stage = stage
            stage.cycles = cycleRange.clamping(stage.cycles)
            stage.phases = stage.phases.prefix(maxPhasesPerStage).map { phase in
                guard let range = range(for: phase.kind) else { return phase }
                var phase = phase
                phase.duration = range.clamping(phase.duration)
                return phase
            }
            return stage
        }
        return clamped
    }
}
