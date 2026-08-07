import BreatheUI
import SwiftUI

/// The carousel's artwork: a soft disc in the technique's colour, idling.
///
/// There are no image assets and a breathing app does not want photography, so
/// the card's picture is drawn — the same orb the marketing site and the phone's
/// home screen use, at wrist size. It breathes slowly whether or not anyone has
/// begun, which is the whole of its job: to be unmistakably alive and to say
/// which technique this is at a glance, by colour.
///
/// A declarative `repeatForever` rather than the phone's `TimelineView`. Ambient
/// motion needs no relationship to a session clock, and every page of the
/// carousel exists at once — a per-frame SwiftUI body evaluation for each of
/// them would be a real cost for a shimmer, where a repeating animation is
/// handed to the render server and costs nothing to keep running.
struct TechniqueOrb: View {
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    /// One breath, in seconds. Slower than the phone's ambient orb: this one is
    /// glanced at rather than watched, and a brisk pulse on the wrist reads as
    /// something needing attention.
    private static let cycle = 4.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.2), lineWidth: 1)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.8), accent.opacity(0.12)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 52
                    )
                )
                .scaleEffect(0.82)
        }
        .scaleEffect(expanded ? 1 : 0.86)
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: Self.cycle / 2).repeatForever(autoreverses: true),
            value: expanded
        )
        .onAppear { expanded = true }
        // Ambience, not information: the name beside it says which technique
        // this is, and nothing here is worth a VoiceOver stop.
        .accessibilityHidden(true)
    }
}
