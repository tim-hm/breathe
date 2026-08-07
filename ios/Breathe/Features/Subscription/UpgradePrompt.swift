import BreatheKit
import BreatheUI
import SwiftUI

/// One line offering an upgrade, wherever the current tier has just met its
/// edge.
///
/// Draws nothing at all for somebody who already holds `tier`, so a caller never
/// has to branch: the condition lives here, in one place, rather than in every
/// surface that could mention a subscription. The affordance is a line of text
/// and a tap, not a banner — this appears next to something somebody is reading,
/// and a card would take the screen away from what they came for.
struct UpgradePrompt: View {
    /// What just happened, in the caller's own words. Passed in rather than
    /// fixed here because "today's answers are from the rules" and "this one is
    /// in the full catalogue" are different moments, and one generic sentence
    /// would be honest about neither.
    let reason: String

    /// What would answer it. Decides both whether to draw at all and which tier
    /// the paywall opens on.
    let tier: SubscriptionTier

    @Environment(SubscriptionStore.self) private var store

    @State private var isShowingPaywall = false

    init(reason: String, offering tier: SubscriptionTier) {
        self.reason = reason
        self.tier = tier
    }

    var body: some View {
        if store.tier < tier {
            Button {
                isShowingPaywall = true
            } label: {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(reason)
                        .foregroundStyle(Theme.Ink.secondary)
                    Text(tier.brandedTitle)
                        .foregroundStyle(Theme.Accent.brand)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.Accent.brand)
                }
                .font(.footnote)
                .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .paywall(highlighting: tier, isPresented: $isShowingPaywall)
        }
    }
}
