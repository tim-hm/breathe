import Foundation

/// The whole plan for one session, laid out on an absolute time axis from t = 0.
///
/// There is no clock inside this type, and that is the point: every question a
/// player asks — which phase is on screen, how far through it, how many cycles
/// are behind you — is a pure function of elapsed time. The animation can ask it
/// once per frame from `TimelineView`, the cue loop can ask it after waking on a
/// `ContinuousClock`, and a test can ask it with no clock at all. Nothing
/// accumulates, so nothing drifts: a late wake-up answers for the time it
/// actually is rather than the time the previous tick expected.
///
/// An open-ended stage is laid out like any other, at the typical length the
/// catalogue seeds it with. The timeline cannot know how long a hold the person
/// ends will actually last, so it does not try: `SessionModel` stops the clock
/// at the hold's start and splices the plan back on at its end.
public struct SessionTimeline: Sendable, Equatable {
    /// One occurrence of a phase, placed at its offset from the start.
    ///
    /// A beat covers `[start, end)`. The half-open interval is what makes the
    /// boundary unambiguous: at exactly `end` the next beat has begun, so a cue
    /// loop that wakes precisely on time fires the arriving phase rather than
    /// the departing one.
    public struct Beat: Sendable, Equatable, Identifiable {
        /// Position in `beats`. Distinguishes two occurrences of the same phase
        /// kind in the same cycle — the physiological sigh's two inhales are one
        /// technique's worth of proof that `kind` alone cannot identify a beat.
        public let id: Int
        public let kind: PhaseKind
        /// Zero-based index of the round this beat belongs to.
        public let round: Int
        /// Zero-based index of the stage within the round.
        public let stage: Int
        /// Zero-based index of the cycle within the stage.
        public let cycle: Int
        /// Whether the person ends this beat rather than the clock. Its
        /// `duration` is then a typical hold, never a scheduled one.
        public let isOpenEnded: Bool
        /// Offset from t = 0.
        public let start: Duration
        public let duration: Duration

        public var end: Duration {
            start + duration
        }

        /// How far through this beat `elapsed` sits, as 0...1.
        ///
        /// Clamped, so a caller that hands over a time outside the beat gets a
        /// still-renderable value rather than an orb scaled past the screen.
        public func fraction(at elapsed: Duration) -> Double {
            let span = duration.milliseconds
            guard span > 0 else { return 1 }
            let offset = Double(elapsed.milliseconds - start.milliseconds) / Double(span)
            return min(max(offset, 0), 1)
        }
    }

    /// Every beat of the session, in play order.
    public let beats: [Beat]
    /// How many times the whole stage list repeats.
    public let rounds: Int
    /// The planned length. An open-ended stage contributes its typical hold, so
    /// this is an estimate for any technique that has one.
    public let totalDuration: Duration

    /// Where each cycle ends, ascending. Precomputed because a cycle boundary is
    /// no longer `elapsed / cycleDuration`: stages have different lengths, so
    /// division would count the short stage's cycles across the long one.
    private let cycleEnds: [Duration]

    /// Lays out `rounds` repetitions of `stages`.
    ///
    /// Counts are floored rather than asserted: a session is not worth trapping
    /// over, and a caller that asks for zero rounds gets one. Empty `stages` is
    /// unreachable from the catalogue — `TechniqueRepository` rejects a
    /// stageless technique — and yields an already-finished timeline rather than
    /// an unadvanceable one.
    public init(stages: [Stage], rounds: Int) {
        let rounds = max(rounds, 1)
        var beats: [Beat] = []
        var cycleEnds: [Duration] = []
        var start = Duration.zero

        for round in 0 ..< rounds {
            for (stageIndex, stage) in stages.enumerated() {
                for cycle in 0 ..< max(stage.cycles, 1) {
                    for phase in stage.phases {
                        beats.append(
                            Beat(
                                id: beats.count,
                                kind: phase.kind,
                                round: round,
                                stage: stageIndex,
                                cycle: cycle,
                                isOpenEnded: stage.openEnded,
                                start: start,
                                duration: phase.duration
                            )
                        )
                        start += phase.duration
                    }
                    cycleEnds.append(start)
                }
            }
        }

        self.beats = beats
        self.rounds = rounds
        self.cycleEnds = cycleEnds
        totalDuration = start
    }

    /// The session a technique describes, at its curated length.
    public init(technique: Technique, rounds: Int? = nil) {
        self.init(stages: technique.stages, rounds: rounds ?? technique.recommendedRounds)
    }

    /// The beat covering `elapsed`, or nil once the session has run out.
    ///
    /// Binary search rather than a scan: a Wim Hof-style session is three rounds
    /// of sixty-plus beats, and this runs on every animation frame.
    public func beat(at elapsed: Duration) -> Beat? {
        guard elapsed >= .zero else { return beats.first }
        guard elapsed < totalDuration else { return nil }

        var low = beats.startIndex
        var high = beats.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if beats[middle].end <= elapsed {
                low = middle + 1
            } else {
                high = middle
            }
        }
        // `elapsed < totalDuration` is `elapsed < beats.last.end`, so the search
        // always lands on a beat rather than past the end.
        return beats[low]
    }

    /// How many cycles are wholly behind `elapsed` — what the summary counts.
    ///
    /// A cycle abandoned three phases in does not count. Someone who stops early
    /// is told what they finished, never what they left.
    public func cyclesCompleted(at elapsed: Duration) -> Int {
        // Counted rather than searched: this answers when a session ends and
        // when a summary draws, not once a frame.
        cycleEnds.count { $0 <= elapsed }
    }

    /// How many inhales are wholly behind `elapsed`.
    ///
    /// Counted per inhale rather than per cycle because the physiological sigh
    /// takes two of them in one cycle, and both are breaths the person took.
    public func breathsCompleted(at elapsed: Duration) -> Int {
        beats.count { $0.kind == .inhale && $0.end <= elapsed }
    }
}
