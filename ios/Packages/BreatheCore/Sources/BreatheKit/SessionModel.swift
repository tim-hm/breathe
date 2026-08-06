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
///
/// Two clocks, though, not one. `elapsed` is a position in the plan and
/// `realElapsed` is time the person actually spent, and an open-ended hold is
/// where they come apart: the timeline cannot know how long a retention lasts,
/// so the plan stops at the hold's start while the wall clock keeps running, and
/// `release()` splices the plan back on at the hold's end. Everything the
/// timeline answers — which phase, how far through, how many cycles — stays a
/// pure function of the plan; everything the person is owed a truthful number
/// for, which is the record, comes off the wall clock.
@MainActor
@Observable
public final class SessionModel {
    public enum Status: Sendable, Equatable {
        case ready
        case running
        /// Inside an open-ended hold, waiting on the person to say they are
        /// ready. The session is not paused: this is the technique working.
        case holding
        case paused
        /// Either outcome: the timeline ran out, or the person ended it. The
        /// distinction lives on `record.completed`.
        case finished
    }

    public let technique: Technique
    /// The stages this session actually plays — the technique's own, or the
    /// dialled versions the person chose on the detail screen.
    public let stages: [Stage]
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

    /// The instant both elapsed times are measured from. Nil while paused, which
    /// is what makes them hold still.
    private var anchor: ContinuousClock.Instant?
    /// Position in the plan banked by previous run segments. Pinned to a hold's
    /// start for as long as the hold lasts.
    private var timelineBanked: Duration = .zero
    /// Wall-clock time banked by previous run segments. Never pinned — a hold is
    /// time the person spent breathing.
    private var realBanked: Duration = .zero
    /// `realElapsed` at the moment the current hold began; nil when not holding.
    /// Survives a pause mid-hold, which is what keeps the hold's own timer from
    /// restarting at zero on resume.
    private var holdBegan: Duration?
    private var startedAt: Date?
    private var cueLoop: Task<Void, Never>?

    public init(
        technique: Technique,
        stages: [Stage]? = nil,
        rounds: Int? = nil,
        cues: any SessionCueing,
        recorder: any SessionRecording
    ) {
        self.technique = technique
        self.stages = stages ?? technique.stages
        timeline = SessionTimeline(
            stages: self.stages,
            rounds: rounds ?? technique.recommendedRounds
        )
        self.cues = cues
        self.recorder = recorder
    }

    /// Where the session is in its plan: frozen while paused, frozen while
    /// holding, and clamped at the end.
    public var elapsed: Duration {
        guard status != .holding, let anchor else { return timelineBanked }
        return min(timelineBanked + anchor.duration(to: clock.now), timeline.totalDuration)
    }

    /// How long the person has been in this session, holds and all.
    ///
    /// Diverges from `elapsed` by however much their retentions ran over or
    /// under the typical hold the catalogue seeds. This is the honest number,
    /// and the one the record keeps.
    public var realElapsed: Duration {
        guard let anchor else { return realBanked }
        return realBanked + anchor.duration(to: clock.now)
    }

    /// How long the current hold has run. Zero when there is no hold.
    public var holdElapsed: Duration {
        guard let holdBegan else { return .zero }
        return realElapsed - holdBegan
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

    /// Which round the person is in, counting from one.
    public var currentRound: Int {
        describingBeat.map { $0.round + 1 } ?? timeline.rounds
    }

    /// Which cycle of the current stage the person is in, counting from one.
    ///
    /// Belongs here rather than in the view: "no current beat means the last
    /// cycle" is what a run-out timeline means, and the summary and the watch
    /// app will need the same answer.
    public var currentCycle: Int {
        describingBeat.map { $0.cycle + 1 } ?? cyclesInCurrentStage
    }

    /// How many cycles the stage on screen plays — the "of 30" in the header.
    public var cyclesInCurrentStage: Int {
        guard let stage = describingBeat?.stage, stages.indices.contains(stage) else {
            return stages.last?.cycles ?? 1
        }
        return stages[stage].cycles
    }

    /// The beat the header describes. Before the cue loop's first turn, and
    /// after the plan runs out, `currentBeat` is nil and the timeline answers.
    private var describingBeat: SessionTimeline.Beat? {
        currentBeat ?? timeline.beat(at: elapsed)
    }

    public func start() {
        guard status == .ready else { return }
        startedAt = .now
        cues.prepare()
        status = .running
        resumeClock()
    }

    public func pause() {
        guard status == .running || status == .holding else { return }
        timelineBanked = elapsed
        realBanked = realElapsed
        anchor = nil
        cueLoop?.cancel()
        cueLoop = nil
        status = .paused
    }

    public func resume() {
        guard status == .paused else { return }
        // A pause inside a hold resumes into the hold, not past it: `holdBegan`
        // outlives the pause, so the hold's own timer picks up where it stopped.
        status = holdBegan == nil ? .running : .holding
        resumeClock()
    }

    /// Ends an open-ended hold — the "tap when you're ready" affordance.
    ///
    /// The plan resumes at the end of the hold's beat however long the hold
    /// actually took: a short retention does not skip the recovery breath, and a
    /// long one does not eat it.
    public func release() {
        guard status == .holding, let beat = currentBeat, beat.isOpenEnded else { return }

        // Banked before the anchor moves, or the hold's time is measured twice.
        realBanked = realElapsed
        timelineBanked = beat.end
        holdBegan = nil
        status = .running
        resumeClock()
    }

    /// Ends the session where it stands. What was finished is still recorded.
    public func end() {
        guard status == .running || status == .holding || status == .paused else { return }
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

            if beat.isOpenEnded {
                beginHold(at: beat)
                return
            }

            guard let anchor else { return }
            try? await clock.sleep(until: anchor.advanced(by: beat.end - timelineBanked))
        }
    }

    /// Stops the plan at the top of a hold the person ends.
    ///
    /// Nothing schedules a wake-up here — that is the whole difference. The plan
    /// is pinned to the hold's start so the phase on screen stays the hold, and
    /// only the wall clock keeps running, which is what the hold's own timer and
    /// the eventual record are read from.
    private func beginHold(at beat: SessionTimeline.Beat) {
        timelineBanked = beat.start
        // Already set when a paused hold resumes; overwriting it would restart
        // the person's hold at zero.
        holdBegan = holdBegan ?? realElapsed
        status = .holding
    }

    private func finish(completed: Bool) {
        cueLoop?.cancel()
        cueLoop = nil

        let elapsed = elapsed
        timelineBanked = elapsed
        realBanked = realElapsed
        anchor = nil
        holdBegan = nil
        status = .finished
        currentBeat = nil

        let record = SessionRecord(
            techniqueSlug: technique.slug,
            startedAt: startedAt ?? .now,
            // Wall-clock, not plan time: an open-ended hold makes the two
            // differ, and what the person did is the one worth keeping.
            duration: realBanked,
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
