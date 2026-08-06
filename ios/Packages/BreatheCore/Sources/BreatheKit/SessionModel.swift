import Foundation
import Observation

/// Whatever turns a phase boundary into something you can feel or hear.
///
/// The player drives this rather than owning it: `CHHapticEngine` and
/// `AVAudioPlayer` are UIKit-era, iOS-only APIs, and the watch app in M9 has a
/// different haptic vocabulary entirely. Keeping the protocol here and the
/// implementations in the app target is what lets the session engine be the same
/// code on both, and lets it run on the host under test with no cues at all.
@MainActor
public protocol SessionCueing {
    /// Called before the first beat. Engine warm-up belongs here, not on the
    /// first boundary, where the latency would land inside the cue.
    func prepare()
    func play(_ beat: SessionTimeline.Beat)
    /// The session reached its end, as opposed to being ended.
    func playCompletion()
    func stop()
}

/// Drives one session: the clock, the phase the person is in, and the record
/// left behind at the end.
///
/// Two readers of one timeline, each on the clock that suits it. The view reads
/// `elapsed` every frame from `TimelineView(.animation)`; this loop sleeps on a
/// `ContinuousClock` until the next boundary's absolute instant and cues it.
/// Neither accumulates: both derive elapsed time by subtracting from a single
/// anchor, so a late frame or a late wake-up is a late answer rather than a
/// permanent offset — which is what a session of twenty bellows cycles would
/// otherwise collect.
@MainActor
@Observable
public final class SessionModel {
    public enum Status: Sendable, Equatable {
        case ready
        case running
        case paused
        /// Either outcome: the timeline ran out, or the person ended it. The
        /// distinction lives on `record.completed`.
        case finished
    }

    public let technique: Technique
    public let timeline: SessionTimeline

    public private(set) var status: Status = .ready
    /// The beat the cue loop most recently entered. The view uses it for the
    /// phase label and the VoiceOver announcement; the animation reads the
    /// timeline directly instead, because it needs a value per frame rather than
    /// per boundary.
    public private(set) var currentBeat: SessionTimeline.Beat?
    /// Set once the session ends — the same value written to the session store,
    /// so the summary screen shows exactly what was recorded.
    public private(set) var record: SessionRecord?

    private let cues: any SessionCueing
    private let recorder: any SessionRecording
    private let clock = ContinuousClock()

    /// The instant `elapsed` is measured from. Nil while paused, which is what
    /// makes `elapsed` hold still.
    private var anchor: ContinuousClock.Instant?
    /// Elapsed time banked by previous run segments.
    private var banked: Duration = .zero
    private var startedAt: Date?
    private var cueLoop: Task<Void, Never>?

    public init(
        technique: Technique,
        cycles: Int,
        cues: any SessionCueing,
        recorder: any SessionRecording
    ) {
        self.technique = technique
        timeline = SessionTimeline(phases: technique.phases, cycles: cycles)
        self.cues = cues
        self.recorder = recorder
    }

    /// Time into the session, frozen while paused and clamped at the end.
    public var elapsed: Duration {
        guard let anchor else { return banked }
        return min(banked + anchor.duration(to: clock.now), timeline.totalDuration)
    }

    /// How far through the whole session, as 0...1 — the progress bar's value.
    ///
    /// Takes the elapsed time rather than reading it, so a view already holding
    /// the value it drew this frame with does not take a second, slightly later
    /// reading off the clock to draw the bar.
    public func progress(at elapsed: Duration) -> Double {
        let total = timeline.totalDuration.milliseconds
        guard total > 0 else { return 1 }
        return Double(elapsed.milliseconds) / Double(total)
    }

    /// Which cycle the person is in, counting from one.
    ///
    /// Belongs here rather than in the view: "no current beat means the last
    /// cycle" is what a run-out timeline means, and the summary and the watch
    /// app will need the same answer.
    public var currentCycle: Int {
        if let currentBeat {
            return currentBeat.cycle + 1
        }
        // Before the cue loop's first turn, and after the timeline runs out.
        return timeline.beat(at: elapsed).map { $0.cycle + 1 } ?? timeline.cycles
    }

    public func start() {
        guard status == .ready else { return }
        startedAt = .now
        cues.prepare()
        status = .running
        resumeClock()
    }

    public func pause() {
        guard status == .running else { return }
        banked = elapsed
        anchor = nil
        cueLoop?.cancel()
        cueLoop = nil
        status = .paused
    }

    public func resume() {
        guard status == .paused else { return }
        status = .running
        resumeClock()
    }

    /// Ends the session where it stands. What was finished is still recorded.
    public func end() {
        guard status == .running || status == .paused else { return }
        finish(completed: false)
    }

    /// Releases the cue hardware. The view calls this as it goes away, rather
    /// than the session ending doing it, so the completion cue has time to play.
    public func dismiss() {
        cueLoop?.cancel()
        cueLoop = nil
        cues.stop()
    }

    private func resumeClock() {
        anchor = clock.now
        cueLoop?.cancel()
        cueLoop = Task { await self.runCueLoop() }
    }

    /// Cues the beat the session is actually in, then sleeps until that beat
    /// ends — an absolute instant, recomputed from the timeline each time round.
    ///
    /// A phase cue is fired on entry only. Resuming mid-phase deliberately does
    /// not re-fire one: the pattern is shaped for a whole phase, and half of one
    /// played over the remainder would misdescribe the breath.
    private func runCueLoop() async {
        while !Task.isCancelled {
            guard let beat = timeline.beat(at: elapsed) else {
                finish(completed: true)
                return
            }

            if beat.id != currentBeat?.id {
                currentBeat = beat
                cues.play(beat)
            }

            guard let anchor else { return }
            try? await clock.sleep(until: anchor.advanced(by: beat.end - banked))
        }
    }

    private func finish(completed: Bool) {
        cueLoop?.cancel()
        cueLoop = nil

        let elapsed = elapsed
        banked = elapsed
        anchor = nil
        status = .finished
        currentBeat = nil

        let record = SessionRecord(
            techniqueSlug: technique.slug,
            startedAt: startedAt ?? .now,
            duration: elapsed,
            cyclesCompleted: timeline.cyclesCompleted(at: elapsed),
            breathCount: timeline.breathsCompleted(at: elapsed),
            completed: completed
        )
        self.record = record

        if completed {
            cues.playCompletion()
        }

        Task { await recorder.record(record) }
    }
}
