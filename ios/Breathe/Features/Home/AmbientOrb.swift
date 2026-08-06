import BreatheUI
import SwiftUI

/// The marketing site's orb, idling on home: a filled dot inside two rings,
/// breathing whether or not anyone has begun.
///
/// It breathes at coherent pace — eleven seconds a cycle, five and a half
/// breaths a minute, the most-studied pace in the catalogue's own copy — so
/// the first thing the app does is model the calm it sells. Anything quicker
/// reads as impatience.
struct AmbientOrb: View {
    /// The wheel's current goal accent, so the orb takes the colour of what
    /// the person is about to do.
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One breath, in seconds.
    private static let cycle = 11.0

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let breath = reduceMotion
                ? 1.0
                : fullness(at: context.date.timeIntervalSinceReferenceDate)

            ZStack {
                Circle()
                    .stroke(accent.opacity(0.15), lineWidth: 1)
                    .scaleEffect(0.90 + 0.10 * breath)

                Circle()
                    .stroke(accent.opacity(0.3), lineWidth: 1)
                    .scaleEffect(0.72 + 0.09 * breath)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.7), accent.opacity(0.15)],
                            center: .center,
                            startRadius: 4,
                            endRadius: 82
                        )
                    )
                    .scaleEffect(0.48 + 0.10 * breath)
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
