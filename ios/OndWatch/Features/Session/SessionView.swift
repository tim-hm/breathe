import OndKit
import OndStyle
import OndUI
import SwiftUI

/// The session on the wrist: one breathing shape filling the face, and as close
/// to nothing else as the session allows.
///
/// Shaped after Mindfulness rather than after the phone. What a person needs
/// mid-breath is the shape moving and the tap on their wrist; a countdown they
/// have to focus on to read is the opposite of the thing being practised. So the
/// digits are gone from the screen — but not from VoiceOver, which has no shape
/// to watch and would otherwise lose the only measure of the phase there is.
///
/// Two further differences from the phone, both deliberate. There is no
/// countdown to the start — a wrist session begins from an explicit tap and the
/// person is already composed. And leaving the app does **not** pause: an
/// extended runtime session keeps the cues firing with the wrist down, which is
/// the posture most of these techniques are done in.
struct SessionView: View {
    @State private var model: SessionModel
    @State private var runtime = ExtendedRuntime()

    /// Whether the pause and end buttons are on screen. Hidden by default: they
    /// are needed twice a session at most, and a breathing guide with a control
    /// bar bolted under it is a control bar somebody is looking at.
    @State private var controlsShown = false
    /// Bumped by every reveal, and the identity of the auto-hide task — a fresh
    /// tap therefore restarts the countdown rather than racing the last one.
    @State private var reveals = 0

    /// Called once a finished session has been read and acknowledged, which is
    /// where the wrist's recordings get their chance to reach the server. Here
    /// rather than on the way out of the catalogue, so the drain cannot start
    /// its RPC in the same instant the extended runtime session does.
    private let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// How long the controls stay up before getting out of the way again.
    private static let controlsLinger = Duration.seconds(4)

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
        // No title. The bar it would sit in is the tallest thing competing with
        // the breath for this screen, and the technique was named on the page
        // the person tapped to get here.
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
        // Keyed on the reveal count, so each tap cancels the previous countdown
        // and starts a fresh one.
        .task(id: reveals) {
            guard reveals > 0 else { return }
            try? await Task.sleep(for: Self.controlsLinger)
            // A paused session keeps its controls: hiding them would leave the
            // only way to resume behind a tap nobody knows to make.
            guard !Task.isCancelled, model.status == .running else { return }
            withAnimation { controlsShown = false }
        }
    }

    private var player: some View {
        ZStack {
            visual

            if model.isInHold {
                hold
            } else {
                phase
            }

            if controlsShown {
                controls
                    .transition(.opacity)
            }
        }
        // The whole face, so a tap anywhere brings the controls back — there is
        // no target to find on a screen that is deliberately almost empty.
        .contentShape(Rectangle())
        .onTapGesture {
            reveals += 1
            withAnimation { controlsShown = true }
        }
    }

    /// `TimelineView(.animation)` redraws every frame and reads the elapsed time
    /// back off the session's clock, so the visual follows the same timeline the
    /// taps do rather than an animation running alongside it. Paused when the
    /// session is, which stops the redraws as well as the breath.
    private var visual: some View {
        TimelineView(.animation(paused: model.status != .running)) { _ in
            let elapsed = model.elapsed

            BreathRing(
                beat: model.timeline.beat(at: elapsed),
                elapsed: elapsed,
                progress: model.progress(at: elapsed),
                accent: model.technique.goal.accent
            )
        }
        // The phase text below is the accessible description of all this.
        .accessibilityHidden(true)
    }

    /// The one word left on screen, and the whole of what VoiceOver is told.
    ///
    /// Ticking once a second rather than once a phase: the word only changes at
    /// a boundary, but the seconds remaining ride on this element's accessibility
    /// value, and those left the visual layer without leaving VoiceOver.
    private var phase: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let elapsed = model.elapsed
            let beat = model.timeline.beat(at: elapsed)

            Text(beat?.kind.instruction ?? "")
                .font(.caption2)
                // Primary ink with a soft shadow, because this word sits on the
                // disc: the accent behind it is mid-luminance, where secondary
                // grey disappears into the colour it is read against.
                .foregroundStyle(Theme.Ink.primary)
                .shadow(color: .black.opacity(0.4), radius: 3)
                .accessibilityElement()
                .accessibilityLabel(beat?.kind.spokenInstruction ?? "")
                .accessibilityValue(beat.map { "\($0.secondsRemaining(at: elapsed))" } ?? "")
        }
    }

    /// The retention. Nothing counts down here, because nothing knows how long
    /// this is: the timer counts up, and the button is the only thing that ends
    /// it. Both stay on screen through a hold whatever the controls are doing —
    /// this button is the only way out of a retention, and the count is the only
    /// feedback a frozen shape can give.
    private var hold: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: Theme.Spacing.close) {
                Text(model.holdElapsed.formatted(.time(pattern: .minuteSecond)))
                    .font(.system(.title3, design: .rounded).weight(.light))
                    .monospacedDigit()
                    // Same contrast rule as the phase word: this count sits on
                    // the frozen disc, not on the black ground.
                    .foregroundStyle(Theme.Ink.primary)
                    .shadow(color: .black.opacity(0.4), radius: 3)
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

    /// Two small glass discs at the foot of the screen.
    ///
    /// Sized rather than left to `.bordered`, which stretches a toolbar-width
    /// button across the face and buries the shape underneath it. These sit over
    /// the breath, so they are the smallest thing a thumb can reliably hit and
    /// no larger.
    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: Theme.Spacing.standard) {
                control(
                    model.status == .paused ? "play.fill" : "pause.fill",
                    label: model.status == .paused ? "Resume" : "Pause",
                    tint: Theme.Ink.primary
                ) {
                    if model.status == .paused {
                        model.resume()
                        // Straight back out of the way: somebody who has just
                        // resumed is watching the shape again.
                        withAnimation { controlsShown = false }
                    } else {
                        model.pause()
                    }
                }

                control("stop.fill", label: "End", tint: Theme.Ink.secondary) {
                    model.end()
                }
            }
            .padding(.bottom, Theme.Spacing.close)
        }
    }

    private func control(
        _ symbol: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
