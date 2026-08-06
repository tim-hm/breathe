import BreatheKit
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
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if reduceMotion {
                ring
            } else {
                orb
            }
        }
        .frame(width: 260, height: 260)
    }

    private var orb: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [accent.opacity(0.85), accent.opacity(0.25)],
                    center: .center,
                    startRadius: 4,
                    endRadius: 130
                )
            )
            .overlay(Circle().stroke(accent.opacity(0.5), lineWidth: 1))
            .scaleEffect(Self.fullness(of: beat, at: elapsed))
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.2), lineWidth: 12)
            Circle()
                .trim(from: 0, to: max(beat?.fraction(at: elapsed) ?? 0, 0.001))
                .stroke(accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(24)
    }

    /// How full the lungs are, 0...1, mapped onto the orb's scale.
    ///
    /// Smoothstepped rather than linear: a breath does not change pace at its
    /// boundaries, and a linear ramp visibly stops dead at the top of an inhale.
    static func fullness(of beat: SessionTimeline.Beat?, at elapsed: Duration) -> Double {
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
