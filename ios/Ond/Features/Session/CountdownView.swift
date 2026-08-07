import OndKit
import OndUI
import SwiftUI

/// The breath before the breathing: a beat to settle before the plan's clock
/// starts. Three seconds, not a preference — long enough to put the phone
/// somewhere and soften the shoulders, short enough that nobody reaches for a
/// skip.
struct CountdownView: View {
    /// Seconds left. The screen presenting this owns the count, because the same
    /// value decides whether this view or the player is on screen at all.
    let count: Int

    @Environment(SessionSettings.self) private var settings

    var body: some View {
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
        // `SessionView.runCountdown` announces each second for VoiceOver, on
        // the same beat the sighted see, so there is nothing here to read.
        .accessibilityHidden(true)
        .sensoryFeedback(.impact(weight: .light), trigger: count) { _, _ in
            settings.cueMode.playsHaptics
        }
    }
}
