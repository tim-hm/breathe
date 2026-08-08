import OndKit
import OndStyle
import OndUI
import SwiftUI

/// The session itself: one animated breath guide, the controls to interrupt it,
/// and the summary it hands over at the end.
struct SessionView: View {
    /// How the screen opens.
    ///
    /// A tap on Begin has already said yes, so the screen counts itself down and
    /// starts — which is every route through the app itself. A notification's
    /// tap has said only "show me this": the person was interrupted rather than
    /// settled, and a breath that begins because a reminder was tapped is the
    /// reminder practising rather than them.
    enum Entry {
        /// Straight into the countdown, because the way in was a Begin control.
        case beginning
        /// At rest, with the exercise named and a Begin control of its own.
        case waiting
    }

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

    /// Whether the screen is still holding, waiting to be asked. False from the
    /// first frame for every entry but a notification's — see `Entry`.
    @State private var isWaiting: Bool

    init(model: SessionModel, entering entry: Entry = .beginning) {
        _model = State(wrappedValue: model)
        _isWaiting = State(wrappedValue: entry == .waiting)
        hints = PhaseHints.hints(for: model.technique)
    }

    var body: some View {
        ZStack {
            if model.status == .finished, let record = model.record, !model.wasDiscarded {
                SessionSummaryView(record: record, technique: model.technique) { dismiss() }
            } else if isWaiting {
                invitation
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
        // and the session is never started under a screen that has gone. Keyed
        // on the flag so that a screen which opened at rest counts down when it
        // is finally asked to, with the same cancellation it would have had.
        .task(id: isWaiting) { await runCountdown() }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.dismiss()
        }
        // `.background` and not `.inactive`, which iOS also sends for a
        // notification banner and a Control Centre pull. The model owns both
        // halves of the decision from here: which pauses undo themselves, and
        // whether the departure is worth pausing for at all — a session still
        // cueing into a dark screen is the app working, not leaving.
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

    /// Counts three seconds down and then starts the session. The guard makes
    /// a re-fired task (or a session already under way) a no-op rather than a
    /// second countdown over a running breath — and holds the count off entirely
    /// on a screen still waiting to be asked.
    private func runCountdown() async {
        guard !isWaiting, model.status == .ready, countdown == nil else { return }

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

    /// The screen at rest: what is about to be practised, how long it runs, and
    /// the two honest answers to being reminded of it.
    ///
    /// "Not now" is as load-bearing as Begin. A reminder that can only be
    /// obeyed is a reminder people turn off, and the way out of a full-screen
    /// cover is otherwise a swipe nobody has been told about.
    private var invitation: some View {
        VStack(spacing: Theme.Spacing.loose) {
            Spacer()

            VStack(spacing: Theme.Spacing.close) {
                Text(model.technique.name)
                    .font(.largeTitle.weight(.medium))
                    .multilineTextAlignment(.center)
                Text(lengthLabel)
                    .font(.body)
            }

            Spacer()

            SafetyNote(technique: model.technique)

            Button("Begin") {
                isWaiting = false
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.close)
            .background(model.technique.goal.accent.opacity(0.2), in: Capsule())

            Button("Not now") {
                dismiss()
            }
            .font(.subheadline)
            .frame(minHeight: 44)
        }
        .padding(Theme.Spacing.loose)
        // Primary is the only ink that clears AA over the accent wash, so there
        // is no tone left to spend on hierarchy here.
        .foregroundStyle(Theme.Ink.primary)
    }

    /// How long the session runs — "about" for a plan the clock owns, "around"
    /// for one whose holds the person ends.
    private var lengthLabel: String {
        let planned = model.technique.plannedDuration
            .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        return model.technique.hasOpenEndedStage ? "Around \(planned)" : "About \(planned)"
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
