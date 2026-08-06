import BreatheKit
import BreatheUI
import SwiftUI

/// The thing you glance at while you breathe, sized for a wrist.
///
/// One shape doing the phone's two jobs at once, because there is only room for
/// one: the disc scales with the breath, and the ring around it fills with the
/// session. Under Reduce Motion the disc holds still and the ring alone carries
/// the phase — the scaling is exactly the effect that setting exists to stop.
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
                .stroke(tint.opacity(0.2), lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))

            disc
        }
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
                    endRadius: 60
                )
            )
            .padding(10)
            .scaleEffect(reduceMotion ? SessionTimeline.Beat.emptyLungs : fullness)
    }

    /// How full the lungs are, mapped straight onto the disc's scale. Empty
    /// before the first beat, which is where a breath starts from.
    private var fullness: Double {
        beat?.lungFullness(at: elapsed) ?? SessionTimeline.Beat.emptyLungs
    }
}
