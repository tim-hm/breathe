import BreatheUI
import SwiftUI

/// The splash: the orb already breathing, and a welcome rather than a form.
/// Centred where every question is leading-aligned — this screen is a greeting,
/// not a step, and the layout should say so.
struct WelcomeStepView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the welcome copy has floated in yet. Starts false so the screen
    /// arrives rather than being merely there.
    ///
    /// Held by this view rather than by the flow around it, so backing out of
    /// the first question replays the entrance — the copy rising to meet the orb
    /// is what this screen is, on the second viewing as much as the first.
    @State private var hasArrived = false

    /// The wordmark's letter spacing, scaled with its own type. A fixed value
    /// beside a Dynamic Type font closes up as the letters grow, which turns
    /// spaced capitals into ordinary ones at exactly the sizes somebody asked
    /// for larger text.
    @ScaledMetric(relativeTo: .body) private var wordmarkTracking: CGFloat = 7

    var body: some View {
        VStack(spacing: Theme.Spacing.loose) {
            AmbientOrb(accent: Theme.Accent.brand)
                .padding(.top, Theme.Spacing.loose)

            VStack(spacing: Theme.Spacing.standard) {
                Text("BREATHE")
                    .font(.system(.body, design: .serif, weight: .medium))
                    .tracking(wordmarkTracking)
                    .foregroundStyle(Theme.Ink.secondary)

                Text("We're glad you're here.")
                    .font(.largeTitle.weight(.medium))
                    .foregroundStyle(Theme.Ink.primary)

                Text(
                    "A few minutes of guided breathing can steady a hard day, "
                        + "settle you towards sleep, or sharpen an afternoon — and "
                        + "you're about to feel it for yourself."
                )
                .font(.body)
                .foregroundStyle(Theme.Ink.secondary)

                Text("Three quick questions first, then we'll get out of your way.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // The one entrance in the app: the words rise to meet the orb,
            // which is already breathing when they arrive.
            .opacity(hasArrived ? 1 : 0)
            .offset(y: hasArrived || reduceMotion ? 0 : 12)
            .animation(.easeOut(duration: 0.8).delay(0.2), value: hasArrived)
        }
        .frame(maxWidth: .infinity)
        .onAppear { hasArrived = true }
    }
}
