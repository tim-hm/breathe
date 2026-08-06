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
        /// Zero-based index of the cycle this beat belongs to.
        public let cycle: Int
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
    /// How many times the cycle repeats.
    public let cycles: Int
    /// One repetition of the technique's cycle.
    public let cycleDuration: Duration
    public let totalDuration: Duration

    /// Lays out `cycles` repetitions of `phases`.
    ///
    /// Both arguments are floored rather than asserted: a session is not worth
    /// trapping over, and a caller that asks for zero cycles gets one. `phases`
    /// arriving empty is unreachable from the catalogue — `TechniqueRepository`
    /// rejects a phaseless technique — and yields an already-finished timeline
    /// rather than an unadvanceable one.
    public init(phases: [Phase], cycles: Int) {
        let cycles = max(cycles, 1)
        var beats: [Beat] = []
        beats.reserveCapacity(phases.count * cycles)

        var start = Duration.zero
        for cycle in 0 ..< cycles {
            for phase in phases {
                beats.append(
                    Beat(
                        id: beats.count,
                        kind: phase.kind,
                        cycle: cycle,
                        start: start,
                        duration: phase.duration
                    )
                )
                start += phase.duration
            }
        }

        self.beats = beats
        self.cycles = cycles
        cycleDuration = phases.reduce(.zero) { $0 + $1.duration }
        totalDuration = start
    }

    /// The session a technique describes, at its curated length.
    public init(technique: Technique, cycles: Int? = nil) {
        self.init(phases: technique.phases, cycles: cycles ?? technique.recommendedCycles)
    }

    /// The beat covering `elapsed`, or nil once the session has run out.
    ///
    /// Binary search rather than a scan: the bellows breath's twenty cycles are
    /// already forty beats, and this runs on every animation frame.
    public func beat(at elapsed: Duration) -> Beat? {
        guard elapsed >= .zero, elapsed < totalDuration else {
            return elapsed < .zero ? beats.first : nil
        }

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
        return low < beats.endIndex ? beats[low] : nil
    }

    /// How many cycles are wholly behind `elapsed` — what the summary counts.
    ///
    /// A cycle abandoned three phases in does not count. Someone who stops early
    /// is told what they finished, never what they left.
    public func cyclesCompleted(at elapsed: Duration) -> Int {
        guard cycleDuration > .zero else { return 0 }
        let completed = elapsed.milliseconds / cycleDuration.milliseconds
        return min(max(Int(completed), 0), cycles)
    }

    /// How many inhales are wholly behind `elapsed`.
    ///
    /// Counted per inhale rather than per cycle because the physiological sigh
    /// takes two of them in one cycle, and both are breaths the person took.
    public func breathsCompleted(at elapsed: Duration) -> Int {
        beats.count { $0.kind == .inhale && $0.end <= elapsed }
    }
}

public extension Duration {
    /// Seconds as a `Double`, for the frameworks that measure time that way —
    /// CoreHaptics pattern events, SwiftUI geometry.
    ///
    /// Never for deciding which phase is current: that stays on the integer
    /// milliseconds below, where a boundary cannot land on the wrong side of
    /// itself by a float's breadth.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}

extension Duration {
    /// Whole milliseconds, truncating.
    ///
    /// Every duration in the catalogue is authored in milliseconds, so integer
    /// arithmetic here is exact where seconds-as-`Double` would land a cycle
    /// boundary a float's breadth on the wrong side of itself.
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
