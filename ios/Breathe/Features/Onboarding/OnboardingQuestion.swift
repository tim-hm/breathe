import BreatheUI
import SwiftUI

/// One question's layout: a heading, a line of context, and whatever it asks.
///
/// Every step but the welcome is built from this, which is what makes the four
/// of them read as one flow rather than four screens — the same measure, the
/// same leading alignment, and one accessibility element for the heading pair so
/// VoiceOver states the question before offering the answers.
struct OnboardingQuestion<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                Text(title)
                    .font(.largeTitle.weight(.medium))
                    .foregroundStyle(Theme.Ink.primary)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
