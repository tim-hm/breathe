import BreatheKit
import BreatheUI
import SwiftUI

/// The goal a technique serves, as a capsule. Shared by the list row and the
/// detail header, which is why it is not private to either.
struct GoalBadge: View {
    let goal: TechniqueGoal

    var body: some View {
        Text(goal.title.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.close)
            .padding(.vertical, Theme.Spacing.tight)
            .background(goal.accent.opacity(0.15), in: Capsule())
            .foregroundStyle(goal.accent)
    }
}
