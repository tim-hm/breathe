import BreatheKit
import BreatheUI
import SwiftUI

/// The home screen's one control: "I want to" beside a wheel of outcomes,
/// reading as one sentence.
///
/// A wheel rather than a menu because spinning through five outcomes is a calmer
/// gesture than opening a list and reading it. The label sits beside the wheel,
/// not above it, because a wheel centres its selection in its own frame —
/// inline, the sentence stays on one line wherever the wheel is spun to. Kept
/// short enough to show the selection and its neighbours and no more: a taller
/// wheel is mostly the empty half above or below whatever is chosen.
///
/// Its own view because both home layouts stand on it. Remembering where it was
/// left is the wheel's own job rather than its caller's, which is why it writes
/// `lastGoal` here: every spin is remembered, and that is the whole of the app's
/// repeat functionality.
struct IntentWheel: View {
    /// The goals the catalogue can actually serve, in the order they are shown.
    let goals: [TechniqueGoal]

    /// Nil until the catalogue has landed and a goal has been settled on.
    @Binding var goal: TechniqueGoal?

    @Environment(SessionSettings.self) private var settings

    var body: some View {
        HStack(spacing: Theme.Spacing.close) {
            Text("I want to")
                .font(.title2)
                .foregroundStyle(Theme.Ink.secondary)

            Picker("I want to", selection: selection) {
                ForEach(goals, id: \.self) { goal in
                    Text(goal.intentObject)
                        .font(.title2.weight(.semibold))
                        .tag(goal)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 205, height: 132)
        }
        // One firm tap as the wheel lands on a choice. An impact rather than
        // `.selection`, which is the lightest haptic there is — under a finger
        // that is actively dragging the wheel it disappears entirely. Skipped
        // for the settle on launch — that is the app restoring state, not the
        // person choosing.
        .sensoryFeedback(.impact(weight: .medium), trigger: goal) { old, _ in old != nil }
    }

    /// Reads the wheel's state, and never writes a goal the catalogue cannot
    /// serve — a `Picker` whose selection is absent from its options renders
    /// blank.
    private var selection: Binding<TechniqueGoal> {
        Binding(
            get: {
                if let goal, goals.contains(goal) {
                    goal
                } else {
                    goals.first ?? .calm
                }
            },
            set: {
                goal = $0
                settings.lastGoal = $0
            }
        )
    }
}
