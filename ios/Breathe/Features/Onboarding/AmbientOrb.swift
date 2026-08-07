import BreatheUI
import SwiftUI

/// The marketing site's orb, idling above the welcome copy: a filled dot inside
/// two rings, breathing whether or not anyone has begun.
///
/// It breathes briskly and visibly — a second and a half in, the same out —
/// with enough travel that the expansion reads as a breath rather than a
/// shimmer. Ambience, not instruction: the session orb swells to be
/// followed; this one only has to be unmistakably alive.
struct AmbientOrb: View {
    /// What colour to breathe in. The welcome screen hands it the brand accent,
    /// because nothing there belongs to a technique yet.
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one thing in the app that reads the appearance directly rather than
    /// through a token, and the reason is that alpha is not a colour: the same
    /// opacity that reads as a lit glow over the near-black ground washes
    /// towards the paper over the white one, worst on the warm accents. The
    /// palette carries a value per appearance and cannot carry an alpha, so the
    /// core's own alphas are what have to know. Dark keeps exactly the numbers
    /// it shipped with.
    @Environment(\.colorScheme) private var colorScheme

    /// One breath, in seconds.
    private static let cycle = 3.0

    var body: some View {
        // Built out here rather than in the closure below, which runs at display
        // refresh: nothing about the colours depends on the time, and the only
        // thing that does is the one number the three scales share.
        let core = RadialGradient(
            colors: [accent.opacity(coreAlpha.centre), accent.opacity(coreAlpha.edge)],
            center: .center,
            startRadius: 4,
            endRadius: 82
        )
        let outerRing = accent.opacity(0.15)
        let innerRing = accent.opacity(0.3)

        return TimelineView(.animation(paused: reduceMotion)) { context in
            let breath = reduceMotion
                ? 1.0
                : fullness(at: context.date.timeIntervalSinceReferenceDate)
            let travel = 0.11 * breath

            // Bases sit `travel` short of where the old ones did, so a full
            // inhale lands the outer ring exactly on the frame's edge.
            ZStack {
                Circle()
                    .stroke(outerRing, lineWidth: 1)
                    .scaleEffect(0.89 + travel)

                Circle()
                    .stroke(innerRing, lineWidth: 1)
                    .scaleEffect(0.70 + travel)

                Circle()
                    .fill(core)
                    .scaleEffect(0.47 + travel)
            }
        }
        .frame(width: 176, height: 176)
        .animation(.easeInOut(duration: 0.5), value: accent)
        // Ambience, not information: nothing here is worth a VoiceOver stop.
        .accessibilityHidden(true)
    }

    /// What the core's radial gradient runs between, at each end.
    private var coreAlpha: (centre: Double, edge: Double) {
        colorScheme == .dark ? (centre: 0.7, edge: 0.15) : (centre: 0.95, edge: 0.45)
    }

    /// How full the lungs are, 0...1, on a cosine so the turn at full and at
    /// empty is soft — the same reason the session orb smoothsteps.
    private func fullness(at time: TimeInterval) -> Double {
        let progress = time.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
        return 0.5 - 0.5 * cos(progress * 2 * .pi)
    }
}
