import BreatheUI
import SwiftUI

/// One answer someone can pick, as a full-width card.
///
/// A card rather than a `Picker` or a list of checkmarks: onboarding asks five
/// questions and each one is the whole screen, so the target should be
/// unmissable and the selected state legible at arm's length. Every one of the
/// three choice steps is drawn with this, which is what keeps them feeling like
/// one flow rather than three screens someone assembled separately.
struct OnboardingChoice: View {
    let title: String
    /// One line under the title, or nil where the title says everything.
    let detail: String?
    let isSelected: Bool
    /// The accent the selected state is drawn in — the goal's own colour on the
    /// goals step, the brand's everywhere else.
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.Ink.primary)

                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Ink.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.standard)
            .background(isSelected ? accent.opacity(0.18) : Theme.Surface.raised, in: card)
            .overlay(card.stroke(isSelected ? accent : Theme.Surface.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        // One element rather than a button wrapping two labels, so VoiceOver
        // reads "I'm new to this, we'll explain what's happening as you go,
        // selected" instead of stopping on the title.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var card: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
    }
}
