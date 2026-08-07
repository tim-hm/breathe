import BreatheKit
import BreatheUI
import SwiftUI

/// The goal a technique serves, as a capsule. Shared by the list row and the
/// detail header, which is why it is not private to either.
///
/// The word is set in ink and the goal's colour is carried by the capsule around
/// it. Drawn the obvious way — accent text on a 0.15 tint of itself — four of
/// the five accents miss AA in the light appearance at the `.caption2` this is
/// set in. `ThemeColorTests` measures the treatment that replaced it.
struct GoalBadge: View {
    let goal: TechniqueGoal

    var body: some View {
        Text(goal.title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.Ink.primary)
            .padding(.horizontal, Theme.Spacing.close)
            .padding(.vertical, Theme.Spacing.tight)
            .background {
                Capsule()
                    .fill(goal.accent.opacity(0.15))
                    .stroke(goal.accent, lineWidth: 1)
            }
    }
}
