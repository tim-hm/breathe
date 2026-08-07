import OndKit
import OndStyle
import OndUI
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

    /// Whether a subscription owns this exercise, in which case pressing opens
    /// the paywall rather than a session. It changes nothing that is drawn —
    /// the aim above the orb already carries the lock, and a second mark on the
    /// one control this screen has would be the screen arguing with itself —
    /// but VoiceOver is told, because "starts the session" would be a lie.
    let isLocked: Bool

    /// How much the screen's width grows the type, 1 on the smallest phones.
    /// A multiplier on a Dynamic Type–scaled base, so the person's text setting
    /// still applies over the top.
    let typeScale: CGFloat

    let action: () -> Void

    /// `title3`'s size as a metric, so `typeScale` multiplies it without
    /// detaching the word from Dynamic Type. A step up from the `headline` it
    /// read at, and one step ahead of the aim word above the orb — the same
    /// gap in emphasis those two had before, at a size that carries an
    /// otherwise empty screen.
    @ScaledMetric(relativeTo: .title3) private var wordSize: CGFloat = 20

    /// The band the word sits in, matching the aim row's so the two words are
    /// equidistant from the orb whatever either one's line height is — which
    /// matching the gaps above and below alone would not achieve.
    @ScaledMetric(relativeTo: .body) private var band: CGFloat = 44

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.loose) {
                AmbientOrb(accent: technique.goal.accent)

                // Lowercase to match the word row at the foot of the screen —
                // a visual choice, and the reason the accessibility label below
                // spells it as a proper sentence instead. VoiceOver reading
                // "begin box breathing" would sound like a fragment.
                Text("begin")
                    .font(.system(size: wordSize * typeScale, weight: .semibold))
                    .foregroundStyle(technique.goal.accent)
                    .frame(minHeight: band)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(OrbPress())
        .accessibilityLabel("Begin \(technique.name)")
        .accessibilityHint(
            isLocked ? "Shows what önd Plus includes" : "Starts the session"
        )
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
                // On the press rather than the release, which is what makes a
                // control feel like a button: the finger is answered while it
                // is still down. Heavier than the aim's step above it, because
                // this is the screen's one committing action.
                .sensoryFeedback(.impact(weight: .heavy), trigger: isPressed) { _, pressed in
                    pressed
                }
        }
    }
}
