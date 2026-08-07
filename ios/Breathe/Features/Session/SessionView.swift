import BreatheKit
import BreatheUI
import SwiftUI

/// The session itself: one animated breath guide, the controls to interrupt it,
/// and the summary it hands over at the end.
struct SessionView: View {
    @State private var model: SessionModel

    /// Per-phase hint lines — which nostril — or nil for the techniques that
    /// need none. Resolved once: the technique cannot change mid-session.
    private let hints: [[String?]]?

    @Environment(SessionSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// The seconds left before the session starts, or nil once it has. The
    /// count is presentation, not part of the session: the recorded duration
    /// starts when the first breath does.
    @State private var countdown: Int?

    init(model: SessionModel) {
        _model = State(wrappedValue: model)
        hints = PhaseHints.hints(for: model.technique)
    }

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()

            if model.status == .finished, let record = model.record, !model.wasDiscarded {
                SessionSummaryView(record: record, technique: model.technique) { dismiss() }
            } else if let countdown {
                getReady(countdown)
            } else {
                player
            }
        }
        .statusBarHidden()
        .onAppear {
            // A guided breath is watched, not touched, so the screen would dim
            // three phases in. Restored on the way out — this is a system-wide
            // setting and leaving it on would outlive the session.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        // `.task` rather than `onAppear`, so dismissing mid-count cancels it
        // and the session is never started under a screen that has gone.
        .task { await runCountdown() }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.dismiss()
        }
        // Haptics do not play in the background and a cue nobody can feel is a
        // phase silently missed, so leaving the app pauses rather than drifts.
        // `.background` and not `.inactive`, which iOS also sends for a
        // notification banner and a Control Centre pull; the model owns which
        // pauses undo themselves.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.pauseForScene()
            case .active: model.resumeIfSceneDriven()
            default: break
            }
        }
        .onChange(of: model.currentBeat?.id) { _, _ in announceCurrentPhase() }
        // A false start — ended by hand inside the first seconds — was never
        // recorded, so there is no summary to show; the screen just goes.
        .onChange(of: model.status) { _, status in
            if status == .finished, model.wasDiscarded {
                dismiss()
            }
        }
    }

    /// The breath before the breathing: a beat to settle before the plan's
    /// clock starts. Three seconds, not a preference — long enough to put the
    /// phone somewhere and soften the shoulders, short enough that nobody
    /// reaches for a skip.
    private func getReady(_ count: Int) -> some View {
        VStack(spacing: Theme.Spacing.loose) {
            VStack(spacing: Theme.Spacing.close) {
                Text("Get comfortable")
                    .font(.title2.weight(.medium))
                Text("Starting in")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Ink.secondary)
            }

            Text("\(count)")
                .font(.system(size: 96, design: .rounded).weight(.light))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(.easeInOut(duration: 0.3), value: count)
        }
        .foregroundStyle(Theme.Ink.primary)
        // The announcements in `runCountdown` carry this for VoiceOver, on
        // the same beat the sighted see.
        .accessibilityHidden(true)
        .sensoryFeedback(.impact(weight: .light), trigger: count) { _, _ in
            settings.cueMode.playsHaptics
        }
    }

    /// Counts three seconds down and then starts the session. The guard makes
    /// a re-fired task (or a session already under way) a no-op rather than a
    /// second countdown over a running breath.
    private func runCountdown() async {
        guard model.status == .ready, countdown == nil else { return }

        for count in [3, 2, 1] {
            countdown = count
            let lead = count == 3 ? "Get comfortable. Starting in " : ""
            AccessibilityNotification.Announcement("\(lead)\(count)").post()
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled {
                return
            }
        }

        countdown = nil
        model.start()
    }

    /// The accent, washed over the palette's own ground rather than over
    /// whatever the presentation put behind it — a translucent gradient alone
    /// would sit on the system's background, which is pure black at night and
    /// paper white by day, and neither is this palette.
    private var backdrop: some View {
        Theme.Surface.ground.overlay(
            LinearGradient(
                colors: [
                    model.technique.goal.accent.opacity(0.35),
                    model.technique.goal.accent.opacity(0.05),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var player: some View {
        VStack(spacing: Theme.Spacing.loose) {
            header

            Spacer()
            if model.isInHold {
                hold
            } else {
                breathGuide
            }
            Spacer()

            // The contraindications belong where the person is, not only where
            // they chose. Compact, because the screen belongs to the breath.
            SafetyNote(technique: model.technique, font: .caption)

            controls
        }
        .padding(Theme.Spacing.loose)
        // Set once for the screen: everything under here is text on the app's
        // own backdrop, and the buttons carry their own tint over it.
        .foregroundStyle(Theme.Ink.primary)
    }

    /// Everything that changes at a phase boundary rather than at display
    /// refresh, so it sits outside the animation timeline below and is rebuilt
    /// when `currentBeat` or `status` changes instead of sixty times a second.
    private var header: some View {
        VStack(spacing: Theme.Spacing.tight) {
            Text(model.technique.name)
                .font(.headline)
            Text(position)
                .font(.subheadline)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    /// "Cycle 3 of 8", or "Round 2 of 3 · cycle 12 of 30" once there are rounds
    /// to keep track of. The round is the number that matters in a staged
    /// protocol, and the cycle is meaningless without it.
    private var position: String {
        let cycle = "Cycle \(model.currentCycle) of \(model.cyclesInCurrentStage)"
        guard model.timeline.rounds > 1 else { return cycle }
        return "Round \(model.currentRound) of \(model.timeline.rounds) · \(cycle.lowercased())"
    }

    /// Two timelines, because only the orb moves at display refresh.
    ///
    /// It redraws every frame and reads elapsed time back off the session's
    /// clock, so the visual follows the same timeline the cues do rather than an
    /// animation running alongside it — paused when the session is.
    ///
    /// The words tick once a second, which is as often as any of them change.
    /// On the frame timeline their combined accessibility element was rebuilt a
    /// hundred times a second, and an accessibility tree invalidated that often
    /// is what makes VoiceOver stutter over the phase instead of reading it.
    private var breathGuide: some View {
        VStack(spacing: Theme.Spacing.loose) {
            TimelineView(.animation(paused: model.status != .running)) { _ in
                let elapsed = model.elapsed
                breathVisual(beat: model.timeline.beat(at: elapsed), elapsed: elapsed)
            }

            // Under Just the visuals the words leave the screen, not the
            // accessibility tree — the orb above then carries them, so a
            // VoiceOver user can always re-read the phase, not only catch
            // its announcement.
            if settings.guidance == .full {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let elapsed = model.elapsed
                    let beat = model.timeline.beat(at: elapsed)

                    VStack(spacing: Theme.Spacing.close) {
                        Text(beat?.kind.instruction ?? "")
                            .font(.title2.weight(.medium))
                        if let hint = PhaseHints.hint(for: beat, in: hints) {
                            Text(hint)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(model.technique.goal.accent)
                        }
                        Text(secondsRemaining(in: beat, at: elapsed))
                            .font(.system(.largeTitle, design: .rounded).weight(.light))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                    // One VoiceOver element for the whole guide: the phase and
                    // how long is left in it, which is everything the visual
                    // conveys.
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// The retention. Nothing counts down here, because nothing knows how long
    /// this is: the timer counts up, and the button is the only thing that ends
    /// it. No target, no record, no encouragement to go longer — a maximal hold
    /// is the one thing this app will not ask anyone for.
    /// A second a tick, not a frame a tick: inside a hold the plan is frozen, so
    /// the orb holds still and the only thing moving on this screen is a timer
    /// counting whole seconds.
    private var hold: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: Theme.Spacing.loose) {
                BreathVisual(
                    beat: model.currentBeat,
                    elapsed: model.elapsed,
                    progress: model.progress(at: model.elapsed),
                    accent: model.technique.goal.accent
                )
                .accessibilityHidden(true)

                VStack(spacing: Theme.Spacing.close) {
                    // The timer stays under Just the visuals — inside a hold
                    // the orb is frozen, so it is the only feedback there is.
                    if settings.guidance == .full {
                        Text(model.currentBeat?.kind.spokenInstruction ?? "")
                            .font(.title2.weight(.medium))
                    }
                    Text(model.holdElapsed.formatted(.time(pattern: .minuteSecond)))
                        .font(.system(.largeTitle, design: .rounded).weight(.light))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Ink.secondary)
                }
                // Explicit label and value rather than combined children, so
                // VoiceOver reads "Hold, lungs empty — 1:23" at every guidance
                // level, including the one that hides the instruction text.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(PhaseHints.spokenPhase(for: model.currentBeat, in: hints))
                .accessibilityValue(model.holdElapsed.formatted(.time(pattern: .minuteSecond)))

                Button("I'm ready") {
                    model.release()
                }
                .font(.headline)
                .padding(.horizontal, Theme.Spacing.loose)
                .padding(.vertical, Theme.Spacing.close)
                .background(.thinMaterial, in: Capsule())
                .disabled(model.status != .holding)
                .accessibilityHint("Ends the hold and takes the recovery breath")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.loose) {
            Button {
                if model.status == .paused {
                    model.resume()
                } else {
                    model.pause()
                }
            } label: {
                Label(
                    model.status == .paused ? "Resume" : "Pause",
                    systemImage: model.status == .paused ? "play.fill" : "pause.fill"
                )
                .labelStyle(.iconOnly)
                .font(.title2)
                .frame(width: 64, height: 64)
                .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel(model.status == .paused ? "Resume" : "Pause")

            Button("End") {
                model.end()
            }
            .font(.headline)
            .foregroundStyle(Theme.Ink.secondary)
        }
        .padding(.bottom, Theme.Spacing.standard)
    }

    /// Whole seconds left in the phase, counting down and never showing zero —
    /// the last second of a phase is still a second of it.
    private func secondsRemaining(in beat: SessionTimeline.Beat?, at elapsed: Duration) -> String {
        guard let beat else { return "" }
        return "\(beat.secondsRemaining(at: elapsed))"
    }

    /// The session's one moving picture, with its accessibility role decided
    /// by guidance: under full the text block beside it speaks for the phase
    /// and the orb stays decorative; under Just the visuals the orb is the
    /// only phase display there is, so it carries the label itself.
    @ViewBuilder
    private func breathVisual(beat: SessionTimeline.Beat?, elapsed: Duration) -> some View {
        let visual = BreathVisual(
            beat: beat,
            elapsed: elapsed,
            progress: model.progress(at: elapsed),
            accent: model.technique.goal.accent
        )

        if settings.guidance == .full {
            visual.accessibilityHidden(true)
        } else {
            visual
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(PhaseHints.spokenPhase(for: beat, in: hints))
                .accessibilityValue(secondsRemaining(in: beat, at: elapsed))
        }
    }

    /// VoiceOver reads the screen once and would otherwise never mention that
    /// the phase changed — which is the only information the session carries.
    /// The nostril hint rides along, whatever the guidance level: wanting a
    /// quieter screen is not the same as hearing nothing.
    private func announceCurrentPhase() {
        guard let beat = model.currentBeat else { return }
        AccessibilityNotification.Announcement(PhaseHints.spokenPhase(for: beat, in: hints)).post()
    }
}
