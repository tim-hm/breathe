import BreatheKit
import BreatheStyle
import BreatheUI
import SwiftUI

/// The retention: the one phase with no end anybody knows in advance.
///
/// Nothing counts down here, because nothing knows how long this is — the timer
/// counts up, and the button is the only thing that ends it. No target, no
/// record, no encouragement to go longer: a maximal hold is the one thing this
/// app will not ask anyone for.
///
/// Its own file rather than a computed property on `SessionView` because it
/// exists for one protocol — Wim Hof's — and the screen around it does not.
struct HoldView: View {
    let model: SessionModel

    /// Per-phase hint lines — which nostril — or nil for the techniques that
    /// need none, resolved once by the screen that presents this.
    let hints: [[String?]]?

    @Environment(SessionSettings.self) private var settings

    /// A second a tick, not a frame a tick: inside a hold the plan is frozen, so
    /// the orb holds still and the only thing moving on this screen is a timer
    /// counting whole seconds.
    var body: some View {
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
}
