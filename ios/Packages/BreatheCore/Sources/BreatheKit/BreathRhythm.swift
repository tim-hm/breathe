import Foundation

/// A technique's breathing pattern as a line — lung fullness over time, in
/// normalised coordinates the detail screen draws before the person commits
/// to a session.
///
/// Pure geometry: x runs 0...1 across the drawn sequence, level runs 0
/// (lungs empty) to 1 (full). The view maps it to points; this type owns
/// every judgement about what the line shows:
///
/// - One cycle per stage. Repetition is a caption ("×30"), not thirty
///   identical humps the eye cannot count.
/// - Width is proportional to time within a stage, but no stage narrower
///   than `minimumStageShare`: a two-second fast-breath cycle beside a
///   minute-long retention would otherwise vanish.
/// - Every segment of an open-ended stage is `dashed` — its durations
///   describe a typical pass, not a scheduled one, and the line should not
///   promise what the clock will not keep.
public struct BreathRhythm: Sendable, Equatable {
    /// One phase of the line, from `(start, startLevel)` to `(end, endLevel)`.
    public struct Segment: Sendable, Equatable {
        public let kind: PhaseKind
        public let start: Double
        public let end: Double
        public let startLevel: Double
        public let endLevel: Double
        /// Whether the phase's length is the person's rather than the clock's.
        public let dashed: Bool

        public init(
            kind: PhaseKind,
            start: Double,
            end: Double,
            startLevel: Double,
            endLevel: Double,
            dashed: Bool
        ) {
            self.kind = kind
            self.start = start
            self.end = end
            self.startLevel = startLevel
            self.endLevel = endLevel
            self.dashed = dashed
        }
    }

    /// The span one stage occupies, for captioning its repeat count.
    public struct Band: Sendable, Equatable {
        public let start: Double
        public let end: Double
        public let cycles: Int

        public init(start: Double, end: Double, cycles: Int) {
            self.start = start
            self.end = end
            self.cycles = cycles
        }
    }

    /// The floor under a stage's share of the width when there is more than
    /// one stage to fit.
    public static let minimumStageShare = 0.18

    public let segments: [Segment]
    /// One per stage, in order. A single-stage technique needs no caption, but
    /// the band is still the honest description of the width it fills.
    public let bands: [Band]

    public init(technique: Technique) {
        let stages = technique.stages
        let durations = stages.map { max($0.cycleDuration.seconds, 0.1) }
        let shares = Self.shares(for: durations)

        var segments: [Segment] = []
        var bands: [Band] = []
        var x = 0.0
        var level = 0.0

        for (stage, share) in zip(stages, shares) {
            let bandStart = x
            let cycleSeconds = max(stage.cycleDuration.seconds, 0.1)

            for (phase, endLevel) in zip(
                stage.phases,
                Self.levels(through: stage.phases, from: level)
            ) {
                let width = share * (phase.duration.seconds / cycleSeconds)
                segments.append(Segment(
                    kind: phase.kind,
                    start: x,
                    end: x + width,
                    startLevel: level,
                    endLevel: endLevel,
                    dashed: stage.openEnded
                ))
                x += width
                level = endLevel
            }

            bands.append(Band(start: bandStart, end: x, cycles: stage.cycles))
        }

        self.segments = segments
        self.bands = bands
    }

    /// Each stage's share of the width: proportional to its one-cycle
    /// duration, with every share lifted to the floor and the rest rescaled
    /// into what remains. Rescaling can push a mid-sized stage below the
    /// floor in turn, so the pass repeats until stable — each pass floors at
    /// least one more stage, bounding the loop by the stage count.
    private static func shares(for durations: [Double]) -> [Double] {
        guard durations.count > 1 else { return [1] }

        let total = durations.reduce(0, +)
        // Never above an equal split, or the floors alone would overflow the
        // width once there are more than five stages.
        let floor = Swift.min(minimumStageShare, 1 / Double(durations.count))
        var floored = [Bool](repeating: false, count: durations.count)
        var shares = durations.map { $0 / total }

        while true {
            let newlyFloored = shares.indices.filter { !floored[$0] && shares[$0] < floor }
            if newlyFloored.isEmpty {
                return shares
            }
            for index in newlyFloored {
                floored[index] = true
            }

            let remaining = 1 - floor * Double(floored.filter(\.self).count)
            let unflooredTotal = durations.indices
                .reduce(0.0) { floored[$1] ? $0 : $0 + durations[$1] }
            shares = durations.indices.map { index in
                floored[index] ? floor : durations[index] / unflooredTotal * remaining
            }
        }
    }

    /// The level each phase ends at.
    ///
    /// An inhale climbs to full and an exhale falls to empty; a run of
    /// consecutive same-kind phases — the physiological sigh's second sip of
    /// air — splits the climb in proportion to each breath's share of the
    /// run's time, so the sip draws as the short top-up it is. A hold keeps
    /// the level it was handed.
    private static func levels(through phases: [Phase], from start: Double) -> [Double] {
        var result: [Double] = []
        var level = start
        var index = 0

        while index < phases.count {
            let kind = phases[index].kind
            switch kind {
            case .holdIn, .holdOut:
                result.append(level)
                index += 1

            case .inhale, .exhale:
                var run: [Phase] = []
                while index < phases.count, phases[index].kind == kind {
                    run.append(phases[index])
                    index += 1
                }

                let target = kind == .inhale ? 1.0 : 0.0
                let runSeconds = run.reduce(0.0) { $0 + $1.duration.seconds }
                var elapsed = 0.0
                for phase in run {
                    elapsed += phase.duration.seconds
                    let endLevel = runSeconds > 0
                        ? level + (target - level) * (elapsed / runSeconds)
                        : target
                    result.append(endLevel)
                }
                level = target
            }
        }

        return result
    }
}
