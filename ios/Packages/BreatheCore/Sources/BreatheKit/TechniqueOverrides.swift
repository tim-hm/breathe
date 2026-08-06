import Foundation

/// A person's dialled-in version of a technique.
///
/// Shaped as parallel arrays rather than keyed by anything, because the thing it
/// has to survive is the catalogue changing underneath it: a technique that
/// gains a phase or loses a stage makes these counts disagree, and a mismatch is
/// the signal to fall back to the curated defaults rather than to guess which
/// old value belonged to which new phase. Client-side until M4's profiles exist
/// to sync it.
public struct TechniqueOverrides: Sendable, Codable, Equatable {
    /// Phase durations in milliseconds, per stage, per phase — the same shape as
    /// the technique's own stages. Milliseconds rather than `Duration` because
    /// this is written to `UserDefaults`: an encoded `Duration` is a pair of
    /// opaque integers, and this file is one somebody may have to read.
    public var phaseDurationsMs: [[Int]]
    /// How many cycles each stage plays.
    public var stageCycles: [Int]
    /// How many times the whole stage list repeats.
    public var rounds: Int

    public init(phaseDurationsMs: [[Int]], stageCycles: [Int], rounds: Int) {
        self.phaseDurationsMs = phaseDurationsMs
        self.stageCycles = stageCycles
        self.rounds = rounds
    }

    /// How far a cycle count may be dialled.
    ///
    /// A constant rather than seeded data, unlike a phase duration: a cycle
    /// count has no evidence-based ceiling, only a point past which the number
    /// stops describing a session anyone will finish.
    public static let cycleRange = 1 ... 99
    /// How far a round count may be dialled. Tighter than the cycles, because
    /// rounds only exist in staged protocols and those are the demanding ones.
    public static let roundRange = 1 ... 10
}

public extension Technique {
    /// This technique exactly as the catalogue curated it — the starting point
    /// every dial moves away from, and what a reset returns to.
    var curatedOverrides: TechniqueOverrides {
        TechniqueOverrides(
            phaseDurationsMs: stages.map { $0.phases.map { Int($0.duration.milliseconds) } },
            stageCycles: stages.map(\.cycles),
            rounds: recommendedRounds
        )
    }

    /// `overrides` if they still describe this technique, the curated settings
    /// otherwise.
    ///
    /// The one place a stored preference is admitted. Everything downstream —
    /// the dials that index these arrays, the session that plays them — works
    /// from the result, so nothing can index a shape the catalogue has since
    /// changed.
    func resolving(_ overrides: TechniqueOverrides?) -> TechniqueOverrides {
        guard let overrides, fits(overrides) else { return curatedOverrides }
        return overrides
    }

    /// This technique as `overrides` dial it: the same catalogue entry, playing
    /// the durations, cycles, and rounds this person chose.
    ///
    /// Returns a `Technique` rather than a pair of values so that stages and
    /// rounds cannot be applied inconsistently — a session built from dialled
    /// stages and a curated round count is a session nobody asked for. Every
    /// value is clamped into the range the catalogue seeded, so a stored
    /// preference cannot outlive a tightened safe range.
    func dialled(with overrides: TechniqueOverrides?) -> Technique {
        let overrides = resolving(overrides)

        let stages = stages.enumerated().map { index, stage in
            let durations = overrides.phaseDurationsMs[index]
            return Stage(
                phases: stage.phases.enumerated().map { phaseIndex, phase in
                    phase.dialled(to: .milliseconds(durations[phaseIndex]))
                },
                cycles: TechniqueOverrides.cycleRange.clamping(overrides.stageCycles[index]),
                openEnded: stage.openEnded
            )
        }

        return Technique(
            id: id,
            slug: slug,
            name: name,
            summary: summary,
            goal: goal,
            stages: stages,
            recommendedRounds: TechniqueOverrides.roundRange.clamping(overrides.rounds),
            safetyNote: safetyNote
        )
    }

    /// Whether `overrides` still describes this technique's shape.
    private func fits(_ overrides: TechniqueOverrides) -> Bool {
        guard overrides.stageCycles.count == stages.count,
              overrides.phaseDurationsMs.count == stages.count
        else {
            return false
        }

        return zip(stages, overrides.phaseDurationsMs).allSatisfy { stage, durations in
            stage.phases.count == durations.count
        }
    }
}

extension ClosedRange {
    /// `value`, brought inside the range.
    func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
