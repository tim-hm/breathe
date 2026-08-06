import BreatheKit
import BreatheUI
import SwiftUI

/// The session on the wrist: the same `SessionModel` the phone drives, with the
/// screen stripped back to what a glance can read.
///
/// Two things differ from the phone, both deliberate. There is no countdown —
/// a wrist session starts from an explicit tap and a person is already
/// composed. And leaving the app does **not** pause: an extended runtime session
/// keeps the cues firing with the wrist down, which is the posture most of these
/// techniques are done in, so pausing on the way there would defeat the feature.
struct SessionView: View {
    @State private var model: SessionModel
    @State private var runtime = ExtendedRuntime()

    /// Called once a finished session has been read and acknowledged, which is
    /// where the wrist's recordings get their chance to reach the server. Here
    /// rather than on the way out of the catalogue, so the drain cannot start
    /// its RPC in the same instant the extended runtime session does.
    private let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    init(model: SessionModel, onFinished: @escaping () -> Void) {
        _model = State(wrappedValue: model)
        self.onFinished = onFinished
    }

    var body: some View {
        Group {
            if model.status == .finished, let record = model.record, !model.wasDiscarded {
                SessionSummaryView(record: record, technique: model.technique) {
                    onFinished()
                    dismiss()
                }
            } else {
                player
            }
        }
        .containerBackground(model.technique.goal.accent.gradient.opacity(0.3), for: .navigation)
        .navigationTitle(model.technique.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            runtime.start()
            model.start()
        }
        .onDisappear {
            runtime.invalidate()
            model.dismiss()
        }
        .onChange(of: model.status) { _, status in
            guard status == .finished else { return }
            // The budget goes back the moment the breathing ends, not when the
            // screen does — a summary being read needs no runtime session.
            runtime.invalidate()
            // A false start — ended by hand inside the first seconds — was never
            // recorded, so there is no summary to show; the screen just goes.
            if model.wasDiscarded {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var player: some View {
        if model.isInHold {
            hold
        } else {
            breathGuide
        }
    }

    /// `TimelineView(.animation)` redraws every frame and reads the elapsed time
    /// back off the session's clock, so the visual follows the same timeline the
    /// taps do rather than an animation running alongside it. Paused when the
    /// session is, which stops the redraws as well as the breath.
    private var breathGuide: some View {
        TimelineView(.animation(paused: model.status != .running)) { _ in
            let elapsed = model.elapsed
            let beat = model.timeline.beat(at: elapsed)
            // Hoisted beside the beat because the label and the VoiceOver value
            // are the same number, and this block runs every frame.
            let remaining = beat.map { "\($0.secondsRemaining(at: elapsed))" } ?? ""

            VStack(spacing: Theme.Spacing.close) {
                BreathRing(
                    beat: beat,
                    elapsed: elapsed,
                    progress: model.progress(at: elapsed),
                    accent: model.technique.goal.accent
                )
                .overlay {
                    VStack(spacing: 0) {
                        Text(beat?.kind.instruction ?? "")
                            .font(.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                        Text(remaining)
                            .font(.system(.title, design: .rounded).weight(.light))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Ink.primary)
                    }
                }
                // One VoiceOver element for the whole guide: the phase and how
                // long is left in it, which is everything the visual conveys.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(beat?.kind.spokenInstruction ?? "")
                .accessibilityValue(remaining)

                controls
            }
        }
    }

    /// The retention. Nothing counts down here, because nothing knows how long
    /// this is: the timer counts up, and the button is the only thing that ends
    /// it. A second a tick rather than a frame a tick — inside a hold the plan
    /// is frozen, so the timer is the only thing moving.
    private var hold: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: Theme.Spacing.close) {
                Text(model.currentBeat?.kind.spokenInstruction ?? "")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                Text(model.holdElapsed.formatted(.time(pattern: .minuteSecond)))
                    .font(.system(.largeTitle, design: .rounded).weight(.light))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.primary)
                    .accessibilityLabel(model.currentBeat?.kind.spokenInstruction ?? "")
                    .accessibilityValue(model.holdElapsed.formatted(.time(pattern: .minuteSecond)))

                Button("I'm ready") {
                    model.release()
                }
                .disabled(model.status != .holding)
                .accessibilityHint("Ends the hold and takes the recovery breath")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.standard) {
            Button {
                if model.status == .paused {
                    model.resume()
                } else {
                    model.pause()
                }
            } label: {
                Image(systemName: model.status == .paused ? "play.fill" : "pause.fill")
            }
            .accessibilityLabel(model.status == .paused ? "Resume" : "Pause")

            Button {
                model.end()
            } label: {
                Image(systemName: "stop.fill")
            }
            .tint(Theme.Ink.secondary)
            .accessibilityLabel("End")
        }
        .buttonStyle(.bordered)
    }
}
