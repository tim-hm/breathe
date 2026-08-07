import BreatheKit
import BreatheStyle
import BreatheUI
import SwiftUI

/// The home screen's one word: the aim, faint above the orb, tappable into the
/// full set.
///
/// At rest it shows only what is chosen — the screen's whole vocabulary is one
/// word, the orb, and "begin". Tapping the word fans every aim the catalogue
/// serves into a row, because a hidden gesture (the swipe the caller owns)
/// needs one visible way to learn what it cycles through. Letter-spaced and
/// lowercase like the tab words below, so the two quiet word treatments read
/// as one system.
///
/// Selection is reported, not stored: the caller owns the goal and its
/// persistence, because the swipe that also changes it lives on the caller's
/// container, and two writers to one choice is one too many.
struct AimSelector: View {
    /// The aims the catalogue can actually serve, in the order they are shown.
    let goals: [TechniqueGoal]

    /// The chosen aim. Non-optional: the caller only renders this view once
    /// the catalogue has landed and a goal has been settled.
    let goal: TechniqueGoal

    /// Whether the row is fanned out. A binding because dismissal is shared:
    /// selecting collapses it here, tapping anywhere else collapses it from
    /// the caller's tap catcher.
    @Binding var isExpanded: Bool

    let onSelect: (TechniqueGoal) -> Void

    var body: some View {
        Group {
            if isExpanded {
                fannedOut
            } else {
                word
            }
        }
        .animation(.easeOut(duration: 0.2), value: isExpanded)
    }

    /// The resting state: one word, one element. Adjustable so VoiceOver keeps
    /// the old wheel's gesture — swipe up or down to step through the aims —
    /// alongside the tap that shows them all.
    private var word: some View {
        Button {
            isExpanded = true
        } label: {
            Text(goal.intentObject)
                .font(.subheadline)
                .kerning(1.6)
                .foregroundStyle(Theme.Ink.tertiary)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: goal)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .accessibilityLabel("I want to")
        .accessibilityValue(goal.intentObject)
        .accessibilityHint("Shows all the aims")
        .accessibilityAdjustableAction { direction in
            let stepped: TechniqueGoal? = switch direction {
            case .increment: goal.next(in: goals)
            case .decrement: goal.previous(in: goals)
            @unknown default: nil
            }
            if let stepped {
                onSelect(stepped)
            }
        }
    }

    private var fannedOut: some View {
        HStack(spacing: Theme.Spacing.standard) {
            ForEach(goals, id: \.self) { aim in
                fannedWord(aim)
            }
        }
        .transition(.opacity)
    }

    private func fannedWord(_ aim: TechniqueGoal) -> some View {
        let isChosen = aim == goal

        return Button {
            onSelect(aim)
            isExpanded = false
        } label: {
            Text(aim.intentObject)
                .font(.subheadline.weight(isChosen ? .semibold : .regular))
                .kerning(1.6)
                .foregroundStyle(isChosen ? aim.accent : Theme.Ink.tertiary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}
