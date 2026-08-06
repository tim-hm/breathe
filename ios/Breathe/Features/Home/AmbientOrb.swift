import BreatheUI
import SwiftUI

/// The marketing site's orb, idling on home: a filled dot inside two rings,
/// breathing whether or not anyone has begun.
///
/// It breathes like a person at rest — ten breaths a minute, with enough
/// travel that the expansion reads as a breath rather than a shimmer.
/// Ambience, not instruction: the session orb swells to be followed; this
/// one only has to be unmistakably alive.
struct AmbientOrb: View {
    /// The wheel's current goal accent, so the orb takes the colour of what
    /// the person is about to do.
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One breath, in seconds.
    private static let cycle = 6.0

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let breath = reduceMotion
                ? 1.0
                : fullness(at: context.date.timeIntervalSinceReferenceDate)

            ZStack {
                Circle()
                    .stroke(accent.opacity(0.15), lineWidth: 1)
                    .scaleEffect(0.92 + 0.08 * breath)

                Circle()
                    .stroke(accent.opacity(0.3), lineWidth: 1)
                    .scaleEffect(0.73 + 0.08 * breath)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.7), accent.opacity(0.15)],
                            center: .center,
                            startRadius: 4,
                            endRadius: 82
                        )
                    )
                    .scaleEffect(0.50 + 0.08 * breath)
            }
        }
        .frame(width: 176, height: 176)
        .animation(.easeInOut(duration: 0.5), value: accent)
        // Ambience, not information: nothing here is worth a VoiceOver stop.
        .accessibilityHidden(true)
    }

    /// How full the lungs are, 0...1, on a cosine so the turn at full and at
    /// empty is soft — the same reason the session orb smoothsteps.
    private func fullness(at time: TimeInterval) -> Double {
        let progress = time.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
        return 0.5 - 0.5 * cos(progress * 2 * .pi)
    }
}
