import BreatheKit
import BreatheUI
import SwiftUI

/// The session itself: one animated breath guide, the controls to interrupt it,
/// and the summary it hands over at the end.
struct SessionView: View {
    @State private var model: SessionModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(model: SessionModel) {
        _model = State(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()

            if model.status == .finished, let record = model.record {
                SessionSummaryView(record: record, technique: model.technique) { dismiss() }
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
            model.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.dismiss()
        }
        // Haptics do not play in the background and a cue nobody can feel is a
        // phase silently missed, so leaving the app pauses rather than drifts.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.pause()
            }
        }
        .onChange(of: model.currentBeat?.id) { _, _ in announceCurrentPhase() }
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [
                model.technique.goal.accent.opacity(0.35),
                model.technique.goal.accent.opacity(0.05),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var player: some View {
        VStack(spacing: Theme.Spacing.loose) {
            header

            Spacer()
            if showsHold {
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
                .foregroundStyle(.secondary)
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

    /// `TimelineView(.animation)` redraws every frame and reads the elapsed time
    /// back off the session's clock, so the visual follows the same timeline the
    /// cues do rather than an animation running alongside it. Paused when the
    /// session is, which stops the redraws as well as the breath.
    private var breathGuide: some View {
        TimelineView(.animation(paused: model.status != .running)) { _ in
            let elapsed = model.elapsed
            let beat = model.timeline.beat(at: elapsed)

            VStack(spacing: Theme.Spacing.loose) {
                BreathVisual(beat: beat, elapsed: elapsed, accent: model.technique.goal.accent)
                    .accessibilityHidden(true)

                VStack(spacing: Theme.Spacing.close) {
                    Text(beat?.kind.instruction ?? "")
                        .font(.title2.weight(.medium))
                    Text(secondsRemaining(in: beat, at: elapsed))
                        .font(.system(.largeTitle, design: .rounded).weight(.light))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // One VoiceOver element for the whole guide: the phase and how
                // long is left in it, which is everything the visual conveys.
                .accessibilityElement(children: .combine)

                ProgressView(value: model.progress(at: elapsed))
                    .tint(model.technique.goal.accent)
                    .accessibilityLabel("Session progress")
            }
        }
    }

    /// The retention. Nothing counts down here, because nothing knows how long
    /// this is: the timer counts up, and the button is the only thing that ends
    /// it. No target, no record, no encouragement to go longer — a maximal hold
    /// is the one thing this app will not ask anyone for.
    /// A paused retention is still a retention: the hold keeps the screen, or
    /// the breath guide would take over and show a countdown from a length this
    /// beat does not really have.
    private var showsHold: Bool {
        model.status == .holding
            || (model.status == .paused && model.currentBeat?.isOpenEnded == true)
    }

    private var hold: some View {
        TimelineView(.animation(paused: model.status != .holding)) { _ in
            VStack(spacing: Theme.Spacing.loose) {
                BreathVisual(
                    beat: model.currentBeat,
                    elapsed: model.elapsed,
                    accent: model.technique.goal.accent
                )
                .accessibilityHidden(true)

                VStack(spacing: Theme.Spacing.close) {
                    Text("Hold, lungs empty")
                        .font(.title2.weight(.medium))
                    Text(model.holdElapsed.formatted(.time(pattern: .minuteSecond)))
                        .font(.system(.largeTitle, design: .rounded).weight(.light))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

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
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, Theme.Spacing.standard)
    }

    /// Whole seconds left in the phase, counting down and never showing zero —
    /// the last second of a phase is still a second of it.
    private func secondsRemaining(in beat: SessionTimeline.Beat?, at elapsed: Duration) -> String {
        guard let beat else { return "" }
        let remaining = (beat.end - elapsed).seconds
        return "\(max(Int(remaining.rounded(.up)), 1))"
    }

    /// VoiceOver reads the screen once and would otherwise never mention that
    /// the phase changed — which is the only information the session carries.
    private func announceCurrentPhase() {
        guard let beat = model.currentBeat else { return }
        AccessibilityNotification.Announcement(beat.kind.spokenInstruction).post()
    }
}
