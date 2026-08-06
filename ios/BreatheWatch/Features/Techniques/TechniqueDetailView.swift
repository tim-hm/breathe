import BreatheKit
import BreatheUI
import SwiftUI

/// What a technique is and what it will ask of you, in the space above a Begin
/// button.
///
/// Deliberately shorter than the phone's: no dials, no rhythm chart, no
/// alternatives. Someone who wants to shape a session does it in their hand;
/// the wrist is for starting the one they already know they want.
struct TechniqueDetailView: View {
    let technique: Technique
    let sessions: any SessionRecording
    let journey: JourneyModel

    @State private var isBreathing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                Text(technique.goal.intent)
                    .font(.caption2)
                    .foregroundStyle(technique.goal.accent)

                Text(technique.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)

                Text(cadence)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.primary)
                    .accessibilityLabel("Pattern")
                    .accessibilityValue(cadence)

                SafetyNote(technique: technique)

                Button("Begin") {
                    isBreathing = true
                }
                .tint(technique.goal.accent)
                .padding(.top, Theme.Spacing.tight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(technique.name)
        // A destination behind a flag rather than a `NavigationLink`, because a
        // link's destination is built with the row it sits in: the session — and
        // the timeline it lays out — would be composed on every pass over this
        // body, and re-composed for a screen nobody opened.
        .navigationDestination(isPresented: $isBreathing) {
            // The drain is hung off the session finishing rather than off this
            // screen going away, because a push counts as going away: every
            // Begin tap would otherwise start a `GetJourney` round-trip in the
            // same instant the extended runtime session does.
            SessionView(model: model()) {
                Task { await journey.sync() }
            }
        }
    }

    /// The pattern in seconds — "4 · 4 · 4 · 4" — which is the one thing about a
    /// technique somebody checks before starting it.
    ///
    /// Read off the first stage only. A staged protocol has no single cadence to
    /// state, and the honest short answer for one is how it opens.
    private var cadence: String {
        guard let stage = technique.stages.first else { return "" }
        return stage.phases
            .map { $0.duration.seconds.formatted(.number.precision(.fractionLength(0 ... 1))) }
            .joined(separator: " · ")
    }

    /// Built at the tap rather than held: a session is a one-shot object, and
    /// one composed when this screen appeared would already have been used by
    /// the time somebody backs out and begins again.
    private func model() -> SessionModel {
        SessionModel(
            technique: technique,
            cues: WatchHapticController(),
            recorder: sessions
        )
    }
}
