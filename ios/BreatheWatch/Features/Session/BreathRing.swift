import BreatheKit
import BreatheUI
import SwiftUI

/// The thing you breathe with, filling the face.
///
/// One shape doing the phone's two jobs at once, because there is only room for
/// one: the disc scales with the breath, and the ring around it fills with the
/// session. Under Reduce Motion the disc gives way to a ring that fills with the
/// phase — the scaling is exactly the effect that setting exists to stop, and a
/// disc merely frozen would leave the wrist with nothing to follow.
///
/// The session ring is drawn thin and at the very edge. It is reference rather
/// than instruction — how far through you are, answered by a glance and never
/// competing with whatever is inside it, which is the thing actually being
/// followed.
struct BreathRing: View {
    let beat: SessionTimeline.Beat?
    let elapsed: Duration
    /// How far through the whole session, 0...1.
    let progress: Double
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            sessionRing

            if reduceMotion {
                phaseRing
            } else {
                disc
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.4), value: isStill)
    }

    /// How far through the session, as quiet chrome at the edge. Kept under
    /// Reduce Motion: a ring that fills over ten minutes is not motion in the
    /// sense that setting suppresses.
    private var sessionRing: some View {
        ring(trim: progress, lineWidth: 3)
    }

    /// The current phase, mirroring the phone's Reduce Motion rendering so the
    /// two devices guide the same breath the same way.
    ///
    /// Trimmed by how far through the beat we are rather than by how full the
    /// lungs are. A hold is what proves the difference: fullness does not move
    /// during one, so a ring driven by it would sit dead for the length of the
    /// phase — which is the state this replaced.
    private var phaseRing: some View {
        ring(trim: beat?.fraction(at: elapsed) ?? 0, lineWidth: 8)
            .padding(10)
    }

    /// A track with a filled arc over it, wound from twelve o'clock. Both rings
    /// on this face are that shape at different weights.
    private func ring(trim: Double, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: trim)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    /// Slate blue while the breath is held, the goal's accent while it moves —
    /// the same shift the phone makes.
    private var tint: Color {
        isStill ? Theme.Accent.still : accent
    }

    private var isStill: Bool {
        beat?.kind.isHold ?? false
    }

    private var disc: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [tint.opacity(0.85), tint.opacity(0.2)],
                    center: .center,
                    startRadius: 2,
                    endRadius: 100
                )
            )
            .padding(6)
            .scaleEffect(fullness)
    }

    /// How full the lungs are, mapped straight onto the disc's scale. Empty
    /// before the first beat, which is where a breath starts from.
    private var fullness: Double {
        beat?.lungFullness(at: elapsed) ?? SessionTimeline.Beat.emptyLungs
    }
}
