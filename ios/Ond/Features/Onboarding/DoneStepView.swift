import OndUI
import SwiftUI

/// The way out, and the one health note the flow carries.
///
/// The caution goes here rather than on the way in: some exercises breathe fast
/// enough to make a person light-headed, and the place to say so is immediately
/// before the first session, not buried in one exercise's small print.
struct DoneStepView: View {
    var body: some View {
        OnboardingQuestion(
            title: "That's it.",
            subtitle: "Everything's saved on this device. Pick something and take a few breaths."
        ) {
            HStack(alignment: .top, spacing: Theme.Spacing.close) {
                Image(systemName: "heart.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.Accent.brand)

                Text(
                    "One thing before you begin: some exercises use quick, deep "
                        + "breathing that can leave you light-headed. Practise sitting "
                        + "or lying down — never while driving or in water — and if "
                        + "anything feels wrong, just breathe normally."
                )
                .font(.footnote)
                .foregroundStyle(Theme.Ink.secondary)
            }
            .padding(Theme.Spacing.standard)
            .glassCard()
            .accessibilityElement(children: .combine)
        }
    }
}
