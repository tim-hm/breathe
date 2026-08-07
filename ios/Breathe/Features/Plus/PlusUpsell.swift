import BreatheKit
import BreatheUI
import SwiftUI

/// One line offering Plus, wherever the free tier has just met its edge.
///
/// Draws nothing at all for a subscriber, so a caller never has to branch: the
/// condition lives here, in one place, rather than in every surface that could
/// mention Plus. The affordance is a line of text and a tap, not a banner —
/// this appears next to an answer somebody is reading, and a card would take
/// the screen away from what they came for.
struct PlusUpsell: View {
    /// What just happened, in the caller's own words. Passed in rather than
    /// fixed here because "today's answers are from the rules" and "this
    /// explanation is the technique's own notes" are different moments, and one
    /// generic sentence would be honest about neither.
    let reason: String

    /// From the environment, so a surface that wants to offer Plus adds one
    /// line and learns nothing about where the subscription comes from.
    @Environment(PlusStore.self) private var store

    @State private var isShowingPaywall = false

    var body: some View {
        if !store.isPlus {
            Button {
                isShowingPaywall = true
            } label: {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(reason)
                        .foregroundStyle(Theme.Ink.secondary)
                    Text("Breathe Plus")
                        .foregroundStyle(Theme.Accent.brand)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.Accent.brand)
                }
                .font(.footnote)
                .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $isShowingPaywall) {
                PaywallView()
            }
        }
    }
}
