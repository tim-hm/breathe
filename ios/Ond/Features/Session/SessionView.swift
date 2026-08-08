import OndKit
import OndStyle
import OndUI
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
            if model.status == .finished, let record = model.record, !model.wasDiscarded {
                SessionSummaryView(record: record, technique: model.technique) { dismiss() }
            } else if let countdown {
                CountdownView(count: countdown)
            } else {
                player
            }
        }
        .accentGround(model.technique.goal.accent)
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
        // A session follows the person out of the app as far as its cues can
        // reach them, and no further: sound reaches a pocket, so a session with
        // it keeps running; nothing else does, so a session without it stops and
        // says that it stopped. One rule, and the half of it about which cues
        // reach a pocket is written on `SessionCues.playsInBackground`.
        //
        // The notice is what makes the stop honest rather than merely quiet, and
        // only a departure that changed something is worth one — which is what
        // `pauseForScene()` answers. The return withdraws it either way, because
        // a departure the notice was never posted for is also one nothing here
        // remembers.
        //
        // `.background` and not `.inactive`, which iOS also sends for a
        // notification banner and a Control Centre pull — neither is a departure
        // and neither should cost the person a phase.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if model.pauseForScene() {
                    SessionPausedNotice.post()
                }

            case .active:
                SessionPausedNotice.withdraw()
                model.resumeIfSceneDriven()

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

    private var player: some View {
        VStack(spacing: Theme.Spacing.loose) {
            header

            Spacer()
            if model.isInHold {
                HoldView(model: model, hints: hints)
            } else {
                breathGuide
            }
            Spacer()

            // The contraindications belong where the person is, not only where
            // they chose. Compact, because the screen belongs to the breath.
            SafetyNote(technique: model.technique)

            controls
        }
        .padding(Theme.Spacing.loose)
        // Set once for the screen: everything under here is text on the accent
        // ground, where primary is the only ink that clears AA, and the buttons
        // carry their own tint over it.
        .foregroundStyle(Theme.Ink.primary)
    }

    /// Everything that changes at a phase boundary rather than at display
    /// refresh, so it sits outside the animation timeline below and is rebuilt
    /// when `currentBeat` or `status` changes instead of sixty times a second.
    private var header: some View {
        VStack(spacing: Theme.Spacing.tight) {
            Text(model.technique.name)
                .font(.headline)
            // Primary ink, quieter only by size: on the accent ground the
            // secondary step measures 3.26:1 and this line is `.subheadline`,
            // so there is no tone left to spend on hierarchy here.
            Text(position)
                .font(.subheadline)
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
                        // Which nostril, and alternate-nostril breathing cannot
                        // be done without it — so it takes the one ink the
                        // accent ground leaves readable. Drawn in the accent it
                        // sits on it measured 2.93:1; the weight is what marks
                        // it out now that the colour cannot.
                        if let hint = PhaseHints.hint(for: beat, in: hints) {
                            Text(hint)
                                .font(.subheadline.weight(.semibold))
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
