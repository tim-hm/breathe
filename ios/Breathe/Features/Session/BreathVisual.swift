import BreatheKit
import BreatheUI
import SwiftUI

/// The thing you watch while you breathe.
///
/// Two renderings of one value. The orb scales with the breath, which is the
/// whole point of it; under Reduce Motion that scaling is exactly the effect
/// that causes trouble, so the same progress drives a ring that fills instead.
struct BreathVisual: View {
    let beat: SessionTimeline.Beat?
    let elapsed: Duration
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                ring
            } else {
                orb
            }
        }
        .frame(width: 260, height: 260)
        .animation(.easeInOut(duration: 0.4), value: tint)
    }

    /// Slate blue while the breath is held, the goal's accent while it moves.
    ///
    /// The same shift the marketing site's orb makes, and the reason it is worth
    /// making here: a hold is the one phase where nothing is scaling, so with
    /// haptics and audio off the colour is all that marks the change.
    private var tint: Color {
        switch beat?.kind {
        case .holdIn, .holdOut: Theme.Accent.hold
        default: accent
        }
    }

    private var orb: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [tint.opacity(0.85), tint.opacity(0.25)],
                    center: .center,
                    startRadius: 4,
                    endRadius: 130
                )
            )
            .overlay(Circle().stroke(tint.opacity(0.5), lineWidth: 1))
            .scaleEffect(fullness)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.2), lineWidth: 12)
            Circle()
                .trim(from: 0, to: beat?.fraction(at: elapsed) ?? 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(24)
    }

    /// How full the lungs are, 0...1, mapped onto the orb's scale.
    ///
    /// Smoothstepped rather than linear: a breath does not change pace at its
    /// boundaries, and a linear ramp visibly stops dead at the top of an inhale.
    private var fullness: Double {
        let smallest = 0.45
        let largest = 1.0

        guard let beat else { return smallest }
        let progress = beat.fraction(at: elapsed)
        let eased = progress * progress * (3 - 2 * progress)

        return switch beat.kind {
        case .inhale: smallest + (largest - smallest) * eased
        case .exhale: largest - (largest - smallest) * eased
        case .holdIn: largest
        case .holdOut: smallest
        }
    }
}
