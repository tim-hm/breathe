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
    /// How far through the whole session, 0...1 — the outer ring's fill.
    let progress: Double
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The session ring's stroke. Thin on purpose: it is reference, not
    /// instruction, and the orb inside it is the thing being followed.
    private static let sessionLineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            sessionRing

            Group {
                if reduceMotion {
                    ring
                } else {
                    orb
                }
            }
            // Clear of the ring, so a full inhale tops out just inside it
            // rather than swallowing it.
            .padding(Theme.Spacing.close)
        }
        .frame(width: 260, height: 260)
        .animation(.easeInOut(duration: 0.4), value: isStill)
    }

    /// How far through the session, as quiet chrome at the edge — the wrist's
    /// treatment, brought back to the phone.
    ///
    /// Kept under Reduce Motion. A ring that fills over ten minutes is not
    /// motion in the sense that setting exists to suppress; it is the same
    /// number the progress bar used to carry, in a place that costs no layout.
    private var sessionRing: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.18), lineWidth: Self.sessionLineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    accent,
                    style: StrokeStyle(lineWidth: Self.sessionLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }

    /// Slate blue while the breath is held, the goal's accent while it moves.
    ///
    /// The same shift the marketing site's orb makes, and the reason it is worth
    /// making here: a hold is the one phase where nothing is scaling, so with
    /// haptics and audio off the colour is all that marks the change.
    private var tint: Color {
        isStill ? Theme.Accent.still : accent
    }

    /// Whether the breath is being held. The animation keys off this rather than
    /// off `tint`, so the crossfade runs on the two boundaries that change the
    /// colour instead of on all four.
    private var isStill: Bool {
        beat?.kind.isHold ?? false
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

    /// How full the lungs are, mapped straight onto the orb's scale. Empty
    /// before the first beat, which is where a breath starts from.
    private var fullness: Double {
        beat?.lungFullness(at: elapsed) ?? SessionTimeline.Beat.emptyLungs
    }
}
