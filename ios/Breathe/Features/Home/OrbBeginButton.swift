import BreatheKit
import BreatheStyle
import BreatheUI
import SwiftUI

/// The orb, as the control that starts the session.
///
/// A circle with no chrome is the least discoverable thing an interface can
/// offer, so this is deliberately more than the circle: the word sits under it,
/// the pair is one accessibility element naming the exercise it will start, and
/// `Button` supplies the trait that tells VoiceOver it can be pressed. The
/// target is the stack's bounds, which are wider and taller than the orb's 176pt
/// frame.
///
/// The orb breathes in the goal's accent rather than the brand's, so the colour
/// answers the wheel above it.
struct OrbBeginButton: View {
    let technique: Technique
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.standard) {
                AmbientOrb(accent: technique.goal.accent)

                // Lowercase to match the word row at the foot of the screen —
                // a visual choice, and the reason the accessibility label below
                // spells it as a proper sentence instead. VoiceOver reading
                // "begin box breathing" would sound like a fragment.
                Text("begin")
                    .font(.headline)
                    .foregroundStyle(technique.goal.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(OrbPress())
        .accessibilityLabel("Begin \(technique.name)")
        .accessibilityHint("Starts the session")
    }
}

/// The orb's pressed state: it shrinks a little and brightens.
///
/// Something has to change visibly under a finger, because there is no fill or
/// border here to darken the way a bordered button's would.
private struct OrbPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Press(isPressed: configuration.isPressed, label: configuration.label)
    }

    /// A view rather than the style body itself: `@Environment` only resolves
    /// inside a `View`, and Reduce Motion decides which half of the pressed
    /// state is drawn. Someone who asked the system for less movement still has
    /// to see that their press landed, so the scale drops out and the brighten
    /// carries it alone.
    private struct Press<Label: View>: View {
        let isPressed: Bool
        let label: Label

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            label
                .scaleEffect(isPressed && !reduceMotion ? 0.95 : 1)
                .brightness(isPressed ? 0.08 : 0)
                .animation(.easeOut(duration: 0.16), value: isPressed)
        }
    }
}
