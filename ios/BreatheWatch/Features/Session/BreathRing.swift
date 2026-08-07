import BreatheKit
import BreatheUI
import SwiftUI

/// The thing you breathe with, filling the face.
///
/// One shape doing the phone's two jobs at once, because there is only room for
/// one: the disc scales with the breath, and the ring around it fills with the
/// session. Under Reduce Motion the disc holds still and the ring alone carries
/// the phase — the scaling is exactly the effect that setting exists to stop.
///
/// The session ring is drawn thin and at the very edge. It is reference rather
/// than instruction — how far through you are, answered by a glance and never
/// competing with the disc, which is the thing actually being followed.
struct BreathRing: View {
    let beat: SessionTimeline.Beat?
    let elapsed: Duration
    /// How far through the whole session, 0...1.
    let progress: Double
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))

            disc
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.4), value: isStill)
    }

    /// Slate blue while the breath is held, the goal's accent while it moves —
    /// the same shift the phone makes, and the only marker of a hold left once
    /// the disc has stopped scaling.
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
            .scaleEffect(reduceMotion ? SessionTimeline.Beat.emptyLungs : fullness)
    }

    /// How full the lungs are, mapped straight onto the disc's scale. Empty
    /// before the first beat, which is where a breath starts from.
    private var fullness: Double {
        beat?.lungFullness(at: elapsed) ?? SessionTimeline.Beat.emptyLungs
    }
}
