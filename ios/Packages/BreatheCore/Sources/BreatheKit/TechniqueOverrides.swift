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

    /// The stages to play, with `overrides` applied wherever they still fit.
    ///
    /// Every value is clamped into the range the catalogue seeded, so a stored
    /// preference cannot outlive a tightened safe range — and a preference whose
    /// shape no longer matches the technique is dropped whole, which is the only
    /// interpretation that cannot silently put a duration on the wrong phase.
    func stages(applying overrides: TechniqueOverrides?) -> [Stage] {
        guard let overrides, fits(overrides) else { return stages }

        return stages.enumerated().map { index, stage in
            let durations = overrides.phaseDurationsMs[index]
            let dialled = stage.phases.enumerated().map { phaseIndex, phase in
                phase.dialled(to: .milliseconds(durations[phaseIndex]))
            }
            return stage.with(phases: dialled).with(cycles: overrides.stageCycles[index])
        }
    }

    /// How many rounds `overrides` asks for, or the curated count when it asks
    /// for nothing this technique can honour.
    func rounds(applying overrides: TechniqueOverrides?) -> Int {
        guard let overrides, fits(overrides) else { return recommendedRounds }
        return TechniqueOverrides.roundRange.clamping(overrides.rounds)
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
