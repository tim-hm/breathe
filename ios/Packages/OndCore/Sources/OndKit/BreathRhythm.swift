import Foundation

/// One stage of a technique that never holds, drawn as a line — lung fullness
/// over time.
///
/// **Slope is the point.** x is duration and y is fullness, so a phase's
/// steepness *is* its length: extended exhale's four-second rise is visibly
/// steeper than its six-second fall, and the asymmetry that names the exercise
/// is stated without a label. This is one construction rather than a library of
/// waveforms — coherent breathing reads as a symmetric sine because its two
/// phases are equal, not because anything here special-cases it.
///
/// Pure geometry: x runs 0...1 across the drawn window, level runs 0 (lungs
/// empty) to 1 (full), or -1...1 when signed. The view maps it to points; this
/// type owns every judgement about what the line shows:
///
/// - **Whole cycles, as many as the window holds.** Slope alone cannot separate
///   coherent breathing from bellows breath — both are one-to-one, so both are
///   symmetric — and the only thing that distinguishes 5½ breaths a minute from
///   twenty fast ones is tempo. Drawing a fixed span of *time* rather than a
///   fixed count of cycles is what puts tempo on the page.
/// - **No phase narrower than `minimumPhaseShare`.** The physiological sigh's
///   0.7-second sip beside its five-second exhale would otherwise render
///   sub-pixel, and the sip is the technique.
/// - **Every segment of an open-ended stage is `dashed`** — its durations
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
        /// Which cycle of the window this segment belongs to, and which phase of
        /// that cycle — so a renderer can label the first cycle only rather than
        /// stamping the same three words across every repeat.
        public let cycle: Int
        public let phase: Int

        /// No defaults on `cycle` and `phase`: they say which segment this *is*,
        /// and a caller that forgot one would get a segment quietly claiming to
        /// be the first phase of the first cycle — which is the one the labels
        /// are drawn from.
        public init(
            kind: PhaseKind,
            start: Double,
            end: Double,
            startLevel: Double,
            endLevel: Double,
            dashed: Bool,
            cycle: Int,
            phase: Int
        ) {
            self.kind = kind
            self.start = start
            self.end = end
            self.startLevel = startLevel
            self.endLevel = endLevel
            self.dashed = dashed
            self.cycle = cycle
            self.phase = phase
        }
    }

    /// The span of breathing a line draws, when the stage repeats often enough
    /// to fill it.
    ///
    /// Twenty-two seconds is long enough to hold two cycles of the slowest
    /// hold-free exercise in the catalogue (coherent breathing, at eleven
    /// seconds a cycle) and eleven of the fastest (bellows, at two) — so the two
    /// that are geometrically identical are never visually similar.
    private static let window = Duration.seconds(22)

    /// The ceiling on repeats. Past a dozen the humps stop being countable and
    /// start being texture, which says "fast" just as well and draws faster.
    private static let maximumCycles = 12

    /// The floor under one phase's share of a cycle.
    private static let minimumPhaseShare = 0.08

    public let segments: [Segment]
    /// How many cycles of the stage the line draws.
    public let cycles: Int
    /// Whether levels run -1...1 about a midline rather than 0...1 above a
    /// baseline. True only where a technique alternates sides.
    public let signed: Bool

    /// How many whole cycles of `stage` fit the window.
    ///
    /// An open-ended stage draws one: there is no clock to fit, and a retention
    /// repeated is not a thing the exercise does.
    private static func cycles(fitting stage: Stage) -> Int {
        guard !stage.openEnded else { return 1 }

        let cycle = max(stage.cycleDuration.seconds, 0.1)
        let fitting = Int((window.seconds / cycle).rounded())
        return min(max(fitting, 1), min(maximumCycles, max(stage.cycles, 1)))
    }

    /// - Parameters:
    ///   - stage: the stage to draw one or more cycles of.
    ///   - signs: one entry per phase of a *cycle*, `+1` above the midline and
    ///     `-1` below, or nil for a one-sided line. Supplied by the caller
    ///     rather than read here, because which side a breath belongs to is a
    ///     presentation fact the catalogue does not carry — see `PhaseHints`.
    public init(stage: Stage, signs: [Double]? = nil) {
        let phases = stage.phases
        let repeats = Self.cycles(fitting: stage)
        let shares = ProportionalShares.of(
            phases.map { max($0.duration.seconds, 0.001) },
            floor: Self.minimumPhaseShare
        )

        var segments: [Segment] = []
        var x = 0.0
        var level = 0.0

        for cycle in 0 ..< repeats {
            for (index, (phase, endLevel)) in zip(
                phases,
                Self.levels(through: phases, from: level)
            ).enumerated() {
                let width = shares[index] / Double(repeats)
                // A one-sided line, and a signs array shorter than the cycle,
                // both mean "above the midline" — the figure stays a drawing
                // rather than half-vanishing below a line it never established.
                let sign = signs?[safe: index] ?? 1

                segments.append(Segment(
                    kind: phase.kind,
                    start: x,
                    end: x + width,
                    // Where the last segment finished, always — which is what
                    // keeps a signed line continuous as it changes side. The
                    // side only ever swaps at empty lungs, so the join lands on
                    // the midline rather than jumping across it.
                    startLevel: segments.last?.endLevel ?? 0,
                    endLevel: endLevel * sign,
                    dashed: stage.openEnded,
                    cycle: cycle,
                    phase: index
                ))
                x += width
                level = endLevel
            }
        }

        self.segments = segments
        cycles = repeats
        signed = signs != nil
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
